"""Local metadata adapters. Never emit prompts, messages, arguments or credentials.

Harness session logs are zstd-compressed; decoding uses Python 3.14+'s stdlib
with third-party/CLI fallbacks. All files/databases are opened read-only.
Output contains status and counts only.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import time


def stamp(value):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 10**11 else value
    try:
        return datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        return 0


def tokens(usage, provider):
    """Normalize Input to INCLUDE Cached, matching Codex's chart contract."""
    if provider == 'DeepSeek Harness':
        cached = usage.get('cacheReadTokens', 0) or 0
        inp = (usage.get('inputTokens', 0) or 0) + cached + (usage.get('cacheWriteTokens', 0) or 0)
        out = usage.get('outputTokens', 0) or 0
    elif provider == 'Claude':
        cached = usage.get('cache_read_input_tokens', 0) or 0
        inp = (usage.get('input_tokens', 0) or 0) + cached + (usage.get('cache_creation_input_tokens', 0) or 0)
        out = usage.get('output_tokens', 0) or 0
    else:
        cached = usage.get('cacheRead', 0) or 0
        inp = (usage.get('input', 0) or 0) + cached + (usage.get('cacheWrite', 0) or 0)
        out = usage.get('output', 0) or 0
    return dict(Input=inp, Cached=cached, Output=out, Total=inp + out)


def parse_events(events, provider, now=None):
    now = now or time.time()
    state, updated, created = 'unknown', 0, 0
    counts = {}
    model, upstream, context_window, last_turn = '', '', 0, None
    for e in events:
        kind = e.get('type', '')
        ts = stamp(e.get('time', e.get('timestamp', e.get('createdAt'))))
        if kind == 'session':
            created = stamp(e.get('createdAt', e.get('timestamp')))
        data = e.get('data') or {}
        # Harness records the selected model and the request's context budget.
        if kind in ('model/selection', 'request/context'):
            model = data.get('model') or model
            upstream = data.get('provider') or upstream
            try:
                context_window = int(data.get('contextWindow') or context_window)
            except (TypeError, ValueError):
                pass
        next_state = None
        if provider == 'DeepSeek Harness':
            next_state = {'turn/start': 'thinking', 'step/start': 'thinking',
                          'tool/call': 'tool', 'tool/result': 'thinking',
                          'approval/request': 'action', 'permission/request': 'action',
                          'approval/resolved': 'thinking'}.get(kind)
            if kind == 'tool/call' and data.get('name', '').split('.')[-1] in ('request_user_input', 'request_user_input_async'):
                next_state = 'action'
            if kind == 'turn/end':
                reason = data.get('reason', {})
                reason = reason.get('kind') if isinstance(reason, dict) else reason
                next_state = {'completed': 'complete', 'aborted': 'stopped', 'error': 'error'}.get(reason, 'unknown')
            if kind == 'assistant/message' and data.get('usage'):
                # stream updates replace the same message's usage, rather than double-counting.
                key = data.get('message', {}).get('id') or str(e.get('seq'))
                counts[key] = tokens(data['usage'], provider)
                last_turn = counts[key]
        else:
            message = e.get('message') or {}
            role = message.get('role', kind)
            if role == 'user':
                next_state = 'thinking'
            elif role in ('toolResult', 'tool'):
                next_state = 'thinking'
            elif role == 'assistant' or kind == 'assistant':
                content = message.get('content') or []
                has_tools = isinstance(content, list) and any(x.get('type') in ('tool_use', 'toolCall') for x in content if isinstance(x, dict))
                stop = message.get('stopReason', message.get('stop_reason'))
                next_state = 'tool' if has_tools else ('complete' if stop in ('stop', 'end_turn', 'stop_sequence') else 'unknown')
                if stop in ('error', 'aborted'):
                    next_state = 'error' if stop == 'error' else 'stopped'
                if message.get('usage'):
                    counts[message.get('id') or e.get('uuid') or e.get('id') or str(ts)] = tokens(message['usage'], provider)
            # Claude's last assistant record may omit stop_reason; do not infer completion.
            if kind in ('approval_request', 'permission_request', 'waiting_for_input'):
                next_state = 'action'
            if kind in ('turn_aborted', 'task_failed', 'task_complete'):
                next_state = {'turn_aborted': 'stopped', 'task_failed': 'error', 'task_complete': 'complete'}[kind]
        if next_state:
            state, updated = next_state, ts
    if state in ('thinking', 'tool') and (not updated or now - updated > 600):
        state = 'unknown'
    usage = {k: sum(v[k] for v in counts.values()) for k in ('Input', 'Cached', 'Output', 'Total')}
    info = dict(State=state, Time=updated, Created=created, Usage=usage, HasUsage=bool(counts))
    if provider == 'DeepSeek Harness':
        # Latest request context (input+cache) against the model's window, plus the
        # last turn's output. This does not expose prompts or message content.
        context = dict(Tokens=0, Cached=0, Output=0, Window=context_window if last_turn else 0,
                       Model=model, Provider=upstream, HasUsage=bool(last_turn))
        if last_turn:
            context.update(Tokens=last_turn['Input'], Cached=last_turn['Cached'], Output=last_turn['Output'])
        info['Context'] = context
    return info


def asks_user(name):
    """Tools that stop the run and wait for the user are not background work."""
    low = (name or '').lower()
    if not low:
        return False
    if low.startswith('interaction.') or 'interaction_' in low:
        return True
    # WorkBuddy's built-in question tool stops the run until the user answers.
    return low.split('.')[-1] in ('ask_user', 'askuser', 'askuserquestion',
                                 'ask_user_question', 'request_user_input',
                                 'request_user_input_async', 'ask')


def parse_doubao(records, mtime, now=None):
    """Doubao's desktop agent mode writes one trajectory per running agent.

    Only the lifecycle shape is read: who spoke last and whether that turn
    carried tool calls. Message text and tool arguments stay on disk.
    """
    now = now or time.time()
    state = 'unknown'
    for e in records:
        if not isinstance(e, dict):
            continue
        role = e.get('role')
        if role in ('user', 'tool'):
            state = 'thinking'
        elif role == 'assistant':
            calls = e.get('tool_calls') or []
            if not calls:
                state = 'complete'
                continue
            names = [((c.get('function') or {}).get('name') or '') for c in calls if isinstance(c, dict)]
            state = 'action' if any(asks_user(n) for n in names) else 'tool'
    if state in ('thinking', 'tool') and (not mtime or now - mtime > 600):
        state = 'unknown'
    return dict(State=state, Time=mtime, Created=mtime, Usage={}, HasUsage=False)


def workbuddy_usage(event):
    """Numbers only. Never read content, reasoning text or tool arguments."""
    data = event.get('providerData') or {}
    if not isinstance(data, dict):
        return None
    usage = data.get('usage') or {}
    if not isinstance(usage, dict) or not usage:
        return None
    raw = data.get('rawUsage') or {}
    if not isinstance(raw, dict):
        raw = {}
    try:
        inp = int(usage.get('inputTokens') or 0)
        out = int(usage.get('outputTokens') or 0)
    except (TypeError, ValueError):
        return None
    cached = 0
    details = usage.get('inputTokensDetails') or []
    if isinstance(details, list):
        for item in details:
            if isinstance(item, dict):
                try:
                    cached += int(item.get('cached_tokens') or 0)
                except (TypeError, ValueError):
                    pass
    if not cached:
        try:
            cached = int(raw.get('prompt_cache_hit_tokens') or
                         raw.get('cache_read_input_tokens') or 0)
        except (TypeError, ValueError):
            cached = 0
    cached = max(0, min(cached, inp))
    quota = raw.get('quota')
    return dict(Input=inp, Cached=cached, Output=out, Total=inp + out,
                Model=str(data.get('requestModelName') or data.get('model') or ''),
                Quota=quota if isinstance(quota, dict) else None)


def parse_workbuddy(events, now=None):
    """WorkBuddy desktop writes one append-only JSONL per project session.

    Lifecycle comes from the structural event type/role/status/tool name and
    token counts from providerData.usage. Prompt text, tool arguments and
    reasoning are never read or emitted.
    """
    now = now or time.time()
    state, updated, created = 'unknown', 0, 0
    usage_by_id, last_turn = {}, None
    model, quota, quota_time = '', None, 0
    ask_pending = False
    for e in events:
        if not isinstance(e, dict):
            continue
        kind = e.get('type', '')
        ts = stamp(e.get('timestamp'))
        if kind == 'session-meta':
            if not created:
                created = ts
            continue
        if kind in ('file-history-snapshot', 'ai-title', 'resend-fork-notice'):
            continue
        data = e.get('providerData') or {}
        if not isinstance(data, dict):
            data = {}
        next_state = None
        if kind == 'message':
            role, status = e.get('role'), e.get('status')
            if role == 'user':
                next_state, ask_pending = 'thinking', False
            elif role == 'assistant':
                if status == 'completed':
                    next_state = 'complete'
                elif status == 'error':
                    next_state = 'error'
                elif status == 'incomplete':
                    # An unfinished answer is either an unresolved question or
                    # an interrupted turn; never claim completion for it.
                    next_state = 'action' if ask_pending else 'unknown'
                else:
                    next_state = 'thinking'
        elif kind == 'reasoning':
            next_state = 'thinking'
        elif kind == 'function_call':
            ask_pending = bool(asks_user(e.get('name')))
            next_state = 'action' if ask_pending else 'tool'
        elif kind == 'function_call_result':
            if e.get('status') == 'completed':
                ask_pending, next_state = False, 'thinking'
            else:
                next_state = 'tool'  # a tool result still being written is running
        if next_state:
            state, updated = next_state, ts or updated
        usage = workbuddy_usage(e)
        if usage:
            key = e.get('id') or (data.get('conversationRequestId'), kind, e.get('name'), ts)
            usage_by_id[key] = usage
            last_turn = usage
            if usage['Model']:
                model = usage['Model']
            q = usage['Quota']
            if q and q.get('percent') is not None and ts >= quota_time:
                quota, quota_time = q, ts
    if state in ('thinking', 'tool') and (not updated or now - updated > 600):
        state = 'unknown'
    totals = {k: sum(v[k] for v in usage_by_id.values())
              for k in ('Input', 'Cached', 'Output', 'Total')}
    context = dict(Tokens=0, Cached=0, Output=0, Window=0, Model=model,
                   Provider='', HasUsage=bool(last_turn))
    if last_turn:
        context.update(Tokens=last_turn['Input'], Cached=last_turn['Cached'],
                       Output=last_turn['Output'])
    info = dict(State=state, Time=updated, Created=created, Usage=totals,
                HasUsage=bool(usage_by_id), Context=context)
    if quota:
        info['Quota'] = dict(used_percent=quota.get('percent'),
                             resets_at=quota.get('reset_at'),
                             model=quota.get('model'))
        info['QuotaTime'] = quota_time
    return info


RUN_PATTERN = re.compile(r'\{\s*"closed":\s*(true|false).{0,160}"conversationId":\s*"([0-9A-Za-z_-]+)".{0,260}?"updatedAt":\s*(\d+)')


def read_doubao_runs(store):
    """Latest run state per conversation from the client's own chat store.

    ``closed`` turns true when a turn ends, which is the only completion marker
    the desktop client persists locally.
    """
    runs = {}
    if not store.exists():
        return runs
    for path in store.iterdir():
        if path.suffix not in ('.log', '.ldb'):
            continue
        try:
            if path.stat().st_size > 32 * 1024 * 1024:
                continue
            text = path.read_bytes().decode('utf-8', 'ignore')
        except OSError:
            continue
        for flag, conversation, updated in RUN_PATTERN.findall(text):
            try:
                stamp = int(updated) / 1000
            except ValueError:
                continue
            state = dict(Closed=flag == 'true', Updated=stamp)
            if conversation not in runs or stamp >= runs[conversation]['Updated']:
                runs[conversation] = state
    return runs


def open_zstd_text(path):
    """Open a Harness .zstd log as UTF-8 text, whatever Python is installed.

    Python 3.14+ ships compression.zstd. On older interpreters prefer an
    installed decoder, then the zstd CLI. A clear ImportError beats silently
    reporting zero Harness sessions (which used to freeze that brand's status).
    """
    try:
        from compression import zstd
        return zstd.open(path, 'rt', encoding='utf-8')
    except ImportError:
        pass
    try:
        import zstandard
        return io.TextIOWrapper(zstandard.ZstdDecompressor().stream_reader(path.open('rb')), encoding='utf-8')
    except ImportError:
        pass
    try:
        import pyzstd
        return pyzstd.open(path, 'rt', encoding='utf-8')
    except ImportError:
        pass
    exe = shutil.which('zstd')
    if exe:
        proc = subprocess.Popen([exe, '-d', '-c', '--no-check', str(path)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return io.TextIOWrapper(proc.stdout, encoding='utf-8')
    raise ImportError('Harness 压缩日志需要 Python 3.14+ 或 zstd 解码器')


def read_events(path):
    handle = open_zstd_text(path) if path.suffix == '.zstd' else path.open(encoding='utf-8')
    with handle:
        # Bound decompressed input; never leave an unbounded reader on a growing log.
        consumed = 0
        for line in handle:
            consumed += len(line)
            if consumed > 64 * 1024 * 1024:
                raise ValueError('log exceeds scan budget')
            try:
                yield json.loads(line)
            except (ValueError, TypeError):
                continue


def read_events_tail(path, budget=262144):
    """Bounded tail reader for the 100 ms channel; growth never stalls the loop."""
    with path.open('rb') as handle:
        handle.seek(0, os.SEEK_END)
        offset = max(0, handle.tell() - budget)
        handle.seek(offset)
        if offset:
            handle.readline()  # drop a possibly truncated first line
        for line in handle:
            try:
                yield json.loads(line.decode('utf-8'))
            except (ValueError, TypeError, UnicodeDecodeError):
                continue


def read_doubao_lifecycle(log_root):
    """Read explicit frontend lifecycle events, never message text or arguments.

    The shell's closed flag describes the tool transport, not the answer. It can
    remain open after cancellation, and does not describe pending approvals.

    The first message of a brand-new conversation is logged BEFORE the server
    assigns a conversation id: its start event carries only
    ``local_conversation_id``. The matching end event carries both ids. Keep
    such a start as a pending turn and retire it once the real conversation
    takes over. Dropping it (as older versions did) makes the first command of
    every new chat invisible on the island and leaves the brand without a busy
    state, which also suppresses the completion animation.
    """
    states = {}
    pending = []
    local_ids = {}
    end_times = []
    decoder = json.JSONDecoder()
    paths = sorted(log_root.glob('saman_frontend_*.log'),
                   key=lambda p: p.stat().st_mtime)[-3:]
    for path in paths:
        date = re.search(r'_(\d{4})\.(\d{4})\.', path.name)
        if not date:
            continue
        try:
            with path.open('rb') as handle:
                size = path.stat().st_size
                handle.seek(max(0, size - 8 * 1024 * 1024))
                if handle.tell():
                    handle.readline()
                lines = handle.read(8 * 1024 * 1024).decode('utf-8', 'ignore').splitlines()
        except OSError:
            continue
        for line in lines:
            if '[logifier-report]' not in line or not any(
                    marker in line for marker in ('on_message_session_',
                                                 'interaction_ask_diagnostic',
                                                 'agent_interaction_submit_diagnostic')):
                continue
            try:
                event, _ = decoder.raw_decode(line[line.index('{'):])
                name = event.get('eventName')
                if name not in ('on_message_session_start', 'on_message_session_end',
                                'interaction_ask_diagnostic', 'agent_interaction_submit_diagnostic'):
                    continue
                clock = re.search(r':(\d{4}/\d{6}\.\d{3}):', line)
                if not clock:
                    continue
                updated = datetime.strptime(date[1] + clock[1], '%Y%m%d/%H%M%S.%f').timestamp()
                meta = event.get('meta') or {}
                conversation = meta.get('conversation_id') or meta.get('conversationId')
                local = str(meta.get('local_conversation_id') or
                            meta.get('send_local_message_id') or '')
                if name == 'on_message_session_end':
                    end_times.append(updated)
                if not conversation:
                    if name == 'on_message_session_start':
                        pending.append(dict(Time=updated, Local=local or 'anonymous'))
                    continue
                if local:
                    local_ids[local] = conversation
                previous = states.get(conversation, {})
                if updated < previous.get('Time', 0):
                    continue
                state = None
                if name == 'on_message_session_start':
                    state = 'thinking'
                elif name == 'on_message_session_end':
                    if meta.get('cancel_source') == 'user':
                        state = 'stopped'
                    elif previous.get('State') == 'action':
                        state = 'action'
                    elif str(meta.get('session_success')) == '1':
                        state = 'complete'
                    else:
                        state = 'error'
                elif previous.get('State') in ('complete', 'stopped', 'error'):
                    # Cleanup/resolve notifications can arrive after the answer
                    # ended. Only an explicit session start opens another turn.
                    continue
                elif meta.get('stage') in ('presenter_acquired', 'message_block_active'):
                    state = 'action'
                elif meta.get('stage') in ('resolved', 'local_resolve', 'submit_success', 'action_completed'):
                    state = 'thinking'
                if state:
                    states[conversation] = dict(State=state, Time=updated)
            except (ValueError, TypeError, AttributeError):
                continue
    for turn in pending:
        real = local_ids.get(turn['Local'])
        if real and states.get(real, {}).get('Time', 0) >= turn['Time']:
            # An end (or a later start) already took over with the real id.
            continue
        if not real and any(t >= turn['Time'] for t in end_times):
            # Fallback for clients that omit the local id altogether.
            continue
        states['pending:' + turn['Local']] = dict(State='thinking', Time=turn['Time'], Pending=True)
    return states


def scan_doubao(home, cache, fresh, now, snapshots=None):
    def read_snapshot(key, directory, patterns, reader):
        if snapshots is None:
            return reader(directory)
        paths = sorted({p for pattern in patterns for p in directory.glob(pattern)})
        version = [(str(p), p.stat().st_size, p.stat().st_mtime_ns) for p in paths]
        previous = snapshots.get(key)
        if previous and previous[0] == version:
            return previous[1]
        value = reader(directory)
        snapshots[key] = (version, value)
        return value
    # Doubao desktop agent mode keeps one trajectory per running agent under the
    # app's own workspace. The app locks its cookie store, so status comes from
    # these trajectories only and the account quota is not readable here.
    bao = Path(os.environ.get('DOUBAO_HOME') or
               (Path(os.environ.get('LOCALAPPDATA') or home / 'AppData' / 'Local') /
                'Doubao' / 'User Data' / 'Default' / '.doubao' / 'agent_mode' / 'workspace' / '.sessions'))
    sessions, warnings = [], []
    conversations = {}
    store = Path(os.environ.get('DOUBAO_STORE') or
                                 (Path(os.environ.get('LOCALAPPDATA') or home / 'AppData' / 'Local') /
                                  'Doubao' / 'User Data' / 'Default' / 'saman_shell_db_storage'))
    runs = read_snapshot('runs', store, ('*.log', '*.ldb'), read_doubao_runs)
    files = sorted(bao.rglob('*/agents/*/system/trajectory.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)[:40] if bao.exists() else []
    for p in files:
        try:
            st = p.stat()
            key, version = str(p), [st.st_size, st.st_mtime_ns]
            cached = cache.get(key)
            if cached and cached.get('Version') == version:
                info = dict(cached['Info'])
            else:
                info = parse_doubao(read_events(p), st.st_mtime, now)
            # The cache keeps the raw trajectory state; the run override below is
            # applied every scan so a stale cached "complete" can never stick.
            fresh[key] = dict(Version=version, Info=info)
            state = info['State']
            if state in ('thinking', 'tool') and now - (info['Time'] or 0) > 600:
                state = 'unknown'
            # A closed run means the turn ended; asking the user also closes it,
            # so that state stays "action" instead of turning into "complete".
            run = runs.get(p.parents[3].name)
            if run and run['Updated'] >= (info['Time'] or 0) - 1 and run['Closed'] and state != 'action':
                if state in ('thinking', 'tool', 'unknown'):
                    state = 'complete'
            session = dict(Id=p.parent.parent.name, State=state, Time=info['Time'])
            sessions.append(session)
            conversation = p.parents[3].name
            if conversation not in conversations or session['Time'] > conversations[conversation]['Time']:
                conversations[conversation] = session
        except (OSError, ValueError, ImportError, EOFError):
            warnings.append('部分会话轨迹不可读')
    log_root = Path(os.environ.get('DOUBAO_LOGS') or
                    (Path(os.environ.get('LOCALAPPDATA') or home / 'AppData' / 'Local') /
                     'Doubao' / 'User Data' / 'sdk_storage' / 'log'))
    lifecycle = read_snapshot('lifecycle', log_root, ('saman_frontend_*.log',), read_doubao_lifecycle)
    # One state per conversation: old worker trajectories must not keep a
    # finished conversation yellow/red, or override its next turn.
    for conversation, event in lifecycle.items():
        if event.get('Pending') and now - event['Time'] > 600:
            # A first turn whose end event never arrived must not keep the
            # island busy forever (e.g. the client was killed mid-request).
            continue
        # Trajectory mtime is a flush time, not a turn boundary. Tool results
        # often flush AFTER cancellation and must not resurrect a finished turn.
        terminal = event['State'] in ('complete', 'stopped', 'error')
        if terminal or conversation not in conversations or event['Time'] >= conversations[conversation]['Time']:
            state = event['State']
            if state == 'thinking' and now - event['Time'] > 600:
                state = 'unknown'
            conversations[conversation] = dict(Id=conversation, State=state, Time=event['Time'])
    return dict(Sessions=sorted(conversations.values(), key=lambda s: s['Time'], reverse=True)[:40],
                Usage=[], Source='豆包本地会话轨迹与客户端生命周期事件', Warning='；'.join(sorted(set(warnings))))


def scan_harness_fast(home, cache, now):
    root = Path(os.environ.get('DSH_HOME') or home / '.dsh') / 'sessions'
    selected = {}
    for path in sorted(root.rglob('session*.jsonl*'), key=lambda p: p.name, reverse=True):
        selected.setdefault(str(path.parent), path)
    sessions, fresh, warning = [], {}, ''
    for path in sorted(selected.values(), key=lambda p: p.stat().st_mtime, reverse=True)[:40]:
        try:
            stat = path.stat()
            version = (stat.st_size, stat.st_mtime_ns)
            previous = cache.get(str(path))
            info = previous[1] if previous and previous[0] == version else parse_events(read_events(path), 'DeepSeek Harness', now)
            fresh[str(path)] = (version, info)
            state = info['State']
            if state in ('thinking', 'tool') and now - info['Time'] > 600:
                state = 'unknown'
            sessions.append(dict(Id=str(path.parent), State=state, Time=info['Time'], Context=info.get('Context')))
        except ImportError as exc:
            # Never let a missing decoder look like "no active sessions": the
            # island would freeze the brand at online and skip every animation.
            warning = str(exc) or 'Harness 压缩日志解码器不可用'
            continue
        except (OSError, ValueError, EOFError):
            continue
    cache.clear()
    cache.update(fresh)
    result = dict(Sessions=sessions, Source='DeepSeek Harness 独立快速生命周期采集')
    if warning:
        result['Warning'] = warning
    return result


def scan_workbuddy(projects, cache, fresh, now, today, limit=40, fast=False):
    """Read the newest WorkBuddy project sessions with a per-file version cache.

    The full scan reads whole files (usage, context, quota). The fast channel
    reads only a bounded tail and reports lifecycle state, so a growing log
    cannot make the 100 ms loop more expensive over time.
    """
    files = sorted(projects.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime,
                   reverse=True)[:limit] if projects.exists() else []
    sessions, usage, warnings = [], [], []
    context, quota, quota_time = None, None, 0
    for p in files:
        try:
            st = p.stat()
            key, version = str(p), [st.st_size, st.st_mtime_ns]
            cached = cache.get(key)
            if cached and cached.get('Version') == version:
                info = cached['Info']
            else:
                reader = read_events_tail(p) if fast else read_events(p)
                info = parse_workbuddy(reader, now)
            fresh[key] = dict(Version=version, Info=info)
            info = dict(info)
            if info['State'] in ('thinking', 'tool') and now - info['Time'] > 600:
                info['State'] = 'unknown'
            sessions.append(dict(Id=p.stem, State=info['State'], Time=info['Time']))
            if fast:
                continue
            created = info['Created'] or st.st_ctime
            if datetime.fromtimestamp(created).astimezone().date() == today and info['HasUsage']:
                usage.append(dict(info['Usage'], Agent='WorkBuddy', File=p.name,
                                  Time=datetime.fromtimestamp(info['Time'] or st.st_mtime,
                                                              timezone.utc).isoformat()))
            candidate = info.get('Context') or {}
            if candidate.get('HasUsage') and (not context or (info['Time'] or 0) >= context[0]):
                context = (info['Time'] or 0, candidate)
            if info.get('Quota') and info.get('QuotaTime', 0) >= quota_time:
                quota, quota_time = info['Quota'], info['QuotaTime']
        except (OSError, ValueError, ImportError, EOFError, TypeError, OverflowError):
            warnings.append('部分会话格式不可读')
    result = dict(Sessions=sorted(sessions, key=lambda s: s['Time'] or 0, reverse=True)[:40],
                  Usage=usage, Source='WorkBuddy 本机会话生命周期与用量日志',
                  Warning='；'.join(sorted(set(warnings))))
    if context:
        result['Context'] = context[1]
    if quota:
        # percent is the provider's used-percent snapshot; the window length is
        # not written locally, so the UI uses a neutral label instead of a guess.
        result['Quota'] = dict(primary=dict(used_percent=quota['used_percent'],
                                            window_minutes=0,
                                            resets_at=quota['resets_at'],
                                            window_label='WorkBuddy 模型额度'))
        result['QuotaTime'] = datetime.fromtimestamp(quota_time, timezone.utc).isoformat()
    return result


def scan_workbuddy_fast(home, cache, now):
    projects = Path(os.environ.get('WORKBUDDY_HOME') or home / '.workbuddy') / 'projects'
    fresh = {}
    detail = scan_workbuddy(projects, cache, fresh, now, None, limit=8, fast=True)
    cache.clear()
    cache.update(fresh)
    return dict(Sessions=detail['Sessions'], Source='WorkBuddy 独立快速生命周期采集')


def scan(home, cache_path):
    home = Path(home)
    dsh = Path(os.environ.get('DSH_HOME') or home / '.dsh')
    claw = Path(os.environ.get('OPENCLAW_STATE_DIR') or home / '.openclaw')
    roots = {'DeepSeek Harness': [(dsh / 'sessions', 'session*.jsonl*')],
             'Claude': [(home / '.claude/projects', '*.jsonl'), (home / '.claude/sessions', '*.jsonl')],
             'OpenClaw': [(claw / 'agents', '*.jsonl')]}
    try:
        cache = json.loads(cache_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        cache = {}
    fresh, result = {}, {}
    now = time.time()
    today = datetime.now().astimezone().date()
    for provider, locations in roots.items():
        files = []
        for root, pattern in locations:
            if root.exists():
                files.extend(root.rglob(pattern))
        # Only the newest generation per Harness session, never count migrated logs twice.
        selected = {}
        for p in sorted(files, key=lambda p: p.name, reverse=True):
            key = str(p.parent) if provider == 'DeepSeek Harness' else str(p)
            selected.setdefault(key, p)
        sessions, usage, warnings = [], [], []
        for p in sorted(selected.values(), key=lambda p: p.stat().st_mtime, reverse=True)[:40]:
            try:
                st = p.stat()
                key, version = str(p), [st.st_size, st.st_mtime_ns]
                cached = cache.get(key)
                # Older caches lack the Harness Context block; reparse once instead of
                # showing an empty usage panel until the log is touched again.
                if cached and cached.get('Version') == version and (provider != 'DeepSeek Harness' or 'Context' in cached.get('Info', {})):
                    info = cached['Info']
                else:
                    info = parse_events(read_events(p), provider, now)
                fresh[key] = dict(Version=version, Info=info)
                info = dict(info)
                if info['State'] in ('thinking', 'tool') and now - info['Time'] > 600:
                    info['State'] = 'unknown'
                session = dict(Id=p.stem, State=info['State'], Time=info['Time'])
                if info.get('Context'):
                    session['Context'] = info['Context']
                sessions.append(session)
                created = info['Created'] or st.st_ctime
                if datetime.fromtimestamp(created).astimezone().date() == today and info['HasUsage']:
                    usage.append(dict(info['Usage'], Agent=provider, File=p.name, Time=datetime.fromtimestamp(info['Time'] or st.st_mtime, timezone.utc).isoformat()))
            except ImportError as exc:
                warnings.append(str(exc) or 'Harness 压缩日志解码器不可用')
            except (OSError, ValueError, EOFError):
                warnings.append('部分会话格式不可读')
        result[provider] = dict(Sessions=sessions, Usage=usage, Source='本机会话生命周期日志', Warning='；'.join(sorted(set(warnings))))
        # Context usage belongs to the most recently active session of this provider.
        context = None
        for session in sorted(sessions, key=lambda s: s.get('Time') or 0, reverse=True):
            if session.get('Context') and session['Context'].get('HasUsage'):
                context = session['Context']
                break
        if context:
            result[provider]['Context'] = context
    result['豆包'] = scan_doubao(home, cache, fresh, now)
    workbuddy_projects = Path(os.environ.get('WORKBUDDY_HOME') or home / '.workbuddy') / 'projects'
    result['WorkBuddy'] = scan_workbuddy(workbuddy_projects, cache, fresh, now, today)
    # Newer OpenClaw versions persist run lifecycle metadata in SQLite.
    db = claw / 'state/openclaw.sqlite'
    if db.exists():
        try:
            with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=0.2) as conn:
                rows = conn.execute('SELECT task_id,status,last_event_at FROM task_runs ORDER BY last_event_at DESC LIMIT 40').fetchall()
                for key, status, ts in rows:
                    state = {'running': 'thinking', 'completed': 'complete', 'failed': 'error', 'cancelled': 'stopped', 'waiting': 'action'}.get(status, 'unknown')
                    ts = stamp(ts)
                    if state == 'thinking' and now - ts > 600:
                        state = 'unknown'
                    result['OpenClaw']['Sessions'].append(dict(Id=key, State=state, Time=ts))
        except sqlite3.Error:
            result['OpenClaw']['Warning'] = '运行记录暂不可读'
    cache_path.write_text(json.dumps(fresh, ensure_ascii=False), encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', default=str(Path.home()))
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--watch-doubao', action='store_true')
    parser.add_argument('--watch-fast', action='store_true')
    args = parser.parse_args()
    if args.watch_doubao or args.watch_fast:
        cache = {}
        snapshots = {}
        harness_cache = {}
        workbuddy_cache = {}
        while True:
            started = time.monotonic()
            try:
                fresh = {}
                detail = scan_doubao(Path(args.home), cache, fresh, time.time(), snapshots)
                cache = fresh
                harness = scan_harness_fast(Path(args.home), harness_cache, time.time())
                workbuddy = scan_workbuddy_fast(Path(args.home), workbuddy_cache, time.time())
                print(json.dumps(dict(Detail=detail, Harness=harness, WorkBuddy=workbuddy,
                                      SampledAt=time.time()), ensure_ascii=True), flush=True)
            except (OSError, ValueError):
                pass
            time.sleep(max(0.01, 0.1 - (time.monotonic() - started)))
    else:
        if not args.cache:
            parser.error('--cache is required unless --watch-fast is used')
        print(json.dumps(scan(args.home, args.cache), ensure_ascii=True))
