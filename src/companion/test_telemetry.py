import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from AgentTelemetry import (asks_user, parse_doubao, parse_events, parse_workbuddy,
                            read_doubao_runs, read_doubao_lifecycle, scan_doubao,
                            scan_harness_fast, scan_workbuddy_fast, tokens, scan)


(Path(__file__).parent / 'data').mkdir(exist_ok=True)

def isolated_home(root):
    """Keep provider homes from the surrounding shell out of fixture scans."""
    return mock.patch.dict(os.environ, {'DSH_HOME': str(root / '.dsh'), 'OPENCLAW_STATE_DIR': str(root / '.openclaw'),
                                        'DOUBAO_HOME': str(root / '.doubao-sessions'),
                                        'DOUBAO_STORE': str(root / '.doubao-store'),
                                        'DOUBAO_LOGS': str(root / '.doubao-logs'),
                                        'WORKBUDDY_HOME': str(root / '.workbuddy')})


class TelemetryTests(unittest.TestCase):
    def test_harness_fast_channel_lifecycle_and_cache(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            folder = root / '.dsh/sessions/work/session-one'
            folder.mkdir(parents=True)
            log = folder / 'session.v4.jsonl'
            cache = {}
            with isolated_home(root):
                for kind, data, expected in [('turn/start', {}, 'thinking'),
                                             ('permission/request', {}, 'action'),
                                             ('tool/call', {}, 'tool'),
                                             ('turn/end', {'reason': {'kind': 'completed'}}, 'complete')]:
                    with log.open('a') as handle:
                        handle.write(json.dumps(dict(type=kind, time=time.time(), data=data)) + '\n')
                    result = scan_harness_fast(root, cache, time.time())
                    self.assertEqual(result['Sessions'][0]['State'], expected)
                    self.assertEqual(scan_harness_fast(root, cache, time.time()), result)
                log.unlink()
                self.assertEqual(scan_harness_fast(root, cache, time.time())['Sessions'], [])

    def test_doubao_frontend_lifecycle_overrides_stuck_transport(self):
        import time
        from datetime import datetime
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            agent = root / '.doubao-sessions/conv/agents/worker/system'
            agent.mkdir(parents=True)
            trajectory = agent / 'trajectory.jsonl'
            trajectory.write_text(json.dumps(dict(role='tool')))
            os.utime(trajectory, (time.time() - 20, time.time() - 20))
            logs = root / '.doubao-logs'
            logs.mkdir()
            now = datetime.now()
            log = logs / ('saman_frontend_' + now.strftime('%Y.%m%d') + '.0.log')
            def emit(name, **meta):
                event = dict(eventName=name, meta=dict(conversation_id='conv', **meta))
                with log.open('a', encoding='utf-8') as f:
                    f.write('[1:2:' + now.strftime('%m%d/%H%M%S.%f')[:-3] +
                            ':INFO:FRONTEND(0)] [logifier-report]: ' + json.dumps(event) + '\", source: (0)\n')
            fast_cache, snapshots = {}, {}
            def state():
                with isolated_home(root):
                    actual = scan(root, root / 'cache.json')['豆包']['Sessions'][0]['State']
                    fresh = {}
                    fast = scan_doubao(root, fast_cache, fresh, time.time(), snapshots)
                    fast_cache.clear()
                    fast_cache.update(fresh)
                    self.assertEqual(fast['Sessions'][0]['State'], actual)
                    return actual
            emit('on_message_session_end', session_success='1')
            self.assertEqual(state(), 'complete')
            # Late tool output and cleanup must not reopen a finished turn.
            os.utime(trajectory, (time.time() + 2, time.time() + 2))
            self.assertEqual(state(), 'complete')
            emit('interaction_ask_diagnostic', stage='resolved')
            self.assertEqual(state(), 'complete')
            os.utime(trajectory, (time.time() - 20, time.time() - 20))
            emit('on_message_session_start')
            self.assertEqual(state(), 'thinking')
            emit('agent_interaction_submit_diagnostic', stage='message_block_active', status=1)
            self.assertEqual(state(), 'action')
            emit('on_message_session_end', session_success='1')
            self.assertEqual(state(), 'action')
            emit('interaction_ask_diagnostic', stage='resolved')
            self.assertEqual(state(), 'thinking')
            emit('on_message_session_end', cancel_source='user', session_success='0')
            self.assertEqual(state(), 'stopped')
            trajectory.write_text(json.dumps(dict(role='tool', content='late result')))
            os.utime(trajectory, (time.time() + 2, time.time() + 2))
            self.assertEqual(state(), 'stopped')
            emit('agent_interaction_submit_diagnostic', stage='action_completed')
            self.assertEqual(state(), 'stopped')
            emit('on_message_session_end', session_success='0')
            self.assertEqual(state(), 'error')
            self.assertEqual(state(), 'error')
            # Only an explicit next turn opens the lifecycle again.
            emit('on_message_session_start')
            self.assertEqual(state(), 'thinking')
            emit('on_message_session_end', session_success='0')
            trajectory.unlink()
            self.assertEqual(state(), 'error')  # ordinary chat needs no trajectory
            self.assertNotIn('meta', str(read_doubao_lifecycle(logs)))

    def test_doubao_first_command_without_conversation_id(self):
        """A new chat's first start event has no server id yet; it must still be busy."""
        import time
        from datetime import datetime, timedelta
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            logs = root / '.doubao-logs'
            logs.mkdir()
            now = datetime.now()
            log = logs / ('saman_frontend_' + now.strftime('%Y.%m%d') + '.0.log')
            tick = [0]
            def emit(name, **meta):
                tick[0] += 1
                stamp = (now + timedelta(seconds=tick[0])).strftime('%m%d/%H%M%S.%f')[:-3]
                event = dict(eventName=name, meta=meta)
                with log.open('a', encoding='utf-8') as f:
                    f.write('[1:2:' + stamp + ':INFO:FRONTEND(0)] [logifier-report]: ' +
                            json.dumps(event) + '", source: (0)\n')
            def sessions(at=None):
                with isolated_home(root):
                    return scan_doubao(root, {}, {}, at or time.time())['Sessions']
            # Brand-new conversation: only local_conversation_id is known.
            emit('on_message_session_start', conversation_id='',
                 local_conversation_id='local_first_command')
            first = sessions()
            self.assertEqual(first[0]['State'], 'thinking')
            self.assertTrue(first[0]['Id'].startswith('pending:'))
            # The answer's end event carries both ids and retires the pending turn,
            # producing the busy -> complete transition the animation needs.
            emit('on_message_session_end', conversation_id='conv-new',
                 local_conversation_id='local_first_command', session_success='1')
            done = sessions()
            self.assertEqual(done[0]['State'], 'complete')
            self.assertEqual(done[0]['Id'], 'conv-new')
            self.assertFalse(any(s['Id'].startswith('pending:') for s in done))
            self.assertEqual(read_doubao_lifecycle(logs)['conv-new']['State'], 'complete')
            # A start whose end never arrives must not keep the island busy.
            emit('on_message_session_start', conversation_id='',
                 local_conversation_id='local_stuck')
            self.assertTrue(any(s['Id'].startswith('pending:') for s in sessions()))
            self.assertFalse(any(s['Id'].startswith('pending:')
                                 for s in sessions(time.time() + 700)))
            self.assertNotIn('meta', str(read_doubao_lifecycle(logs)))

    def test_doubao_pending_turn_retired_without_local_id(self):
        from datetime import datetime, timedelta
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            logs = Path(tmp) / '.doubao-logs'
            logs.mkdir()
            now = datetime.now()
            log = logs / ('saman_frontend_' + now.strftime('%Y.%m%d') + '.0.log')
            tick = [0]
            def emit(name, **meta):
                tick[0] += 1
                stamp = (now + timedelta(seconds=tick[0])).strftime('%m%d/%H%M%S.%f')[:-3]
                with log.open('a', encoding='utf-8') as f:
                    f.write('[1:2:' + stamp + ':INFO:FRONTEND(0)] [logifier-report]: ' +
                            json.dumps(dict(eventName=name, meta=meta)) + '", source: (0)\n')
            emit('on_message_session_start', conversation_id='')
            self.assertTrue(any(k.startswith('pending:') for k in read_doubao_lifecycle(logs)))
            emit('on_message_session_end', conversation_id='conv-x', session_success='1')
            states = read_doubao_lifecycle(logs)
            self.assertFalse(any(k.startswith('pending:') for k in states))
            self.assertEqual(states['conv-x']['State'], 'complete')

    def test_harness_lifecycle_and_stale(self):
        events = [dict(type='turn/start', time=1000000), dict(type='tool/call', time=1000001, data={})]
        self.assertEqual(parse_events(events, 'DeepSeek Harness', 1000002)['State'], 'tool')
        self.assertEqual(parse_events(events, 'DeepSeek Harness', 1000700)['State'], 'unknown')
        events.append(dict(type='turn/end', time=1000002, data={'reason': {'kind': 'completed'}}))
        self.assertEqual(parse_events(events, 'DeepSeek Harness', 1000003)['State'], 'complete')
        for reason, expected in [('aborted', 'stopped'), ('error', 'error')]:
            events[-1]['data']['reason']['kind'] = reason
            self.assertEqual(parse_events(events, 'DeepSeek Harness', 1000003)['State'], expected)

    def test_cache_normalization_and_stream_dedup(self):
        usage = {'inputTokens': 10, 'cacheReadTokens': 80, 'outputTokens': 20}
        events = [dict(type='assistant/message', time=1000, data={'message': {'id': 'a'}, 'usage': usage})] * 2
        actual = parse_events(events, 'DeepSeek Harness', 1000)['Usage']
        self.assertEqual(actual, dict(Input=90, Cached=80, Output=20, Total=110))
        self.assertEqual(tokens({'input_tokens': 10, 'cache_read_input_tokens': 80, 'cache_creation_input_tokens': 5, 'output_tokens': 20}, 'Claude')['Total'], 115)

    def test_claw_tools_and_completion(self):
        events = [dict(type='message', timestamp=1000, message={'role': 'assistant', 'content': [{'type': 'toolCall'}], 'stopReason': 'toolUse'})]
        self.assertEqual(parse_events(events, 'OpenClaw', 1001)['State'], 'tool')
        events.append(dict(type='message', timestamp=1002, message={'role': 'assistant', 'content': [], 'stopReason': 'stop', 'usage': {'input': 5, 'cacheRead': 10, 'output': 2}}))
        actual = parse_events(events, 'OpenClaw', 1003)
        self.assertEqual(actual['State'], 'complete')
        self.assertEqual(actual['Usage']['Total'], 17)

    def test_doubao_trajectory_states(self):
        records = [dict(role='user', content='go')]
        self.assertEqual(parse_doubao(records, 1000, 1001)['State'], 'thinking')
        records.append(dict(role='assistant', content=None, tool_calls=[{'function': {'name': 'PowerShell'}}]))
        self.assertEqual(parse_doubao(records, 1000, 1001)['State'], 'tool')
        self.assertEqual(parse_doubao(records, 300, 1001)['State'], 'unknown')
        records.append(dict(role='tool', content='ok'))
        self.assertEqual(parse_doubao(records, 1000, 1001)['State'], 'thinking')
        records.append(dict(role='assistant', content='done'))
        self.assertEqual(parse_doubao(records, 1000, 1001)['State'], 'complete')
        records[-1] = dict(role='assistant', content=None, tool_calls=[{'function': {'name': 'interaction.ask'}}])
        self.assertEqual(parse_doubao(records, 1000, 1001)['State'], 'action')
        self.assertTrue(asks_user('interaction.ask'))
        self.assertTrue(asks_user('interaction_request_action'))
        self.assertFalse(asks_user('PowerShell'))

    def test_scan_uses_closed_run_for_completion(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / "data") as tmp:
            root = Path(tmp)
            agent = root / '.doubao-sessions' / 'conv-1' / 'agents' / 'worker' / 'system'
            agent.mkdir(parents=True)
            (agent / 'trajectory.jsonl').write_text('\n'.join(json.dumps(e) for e in [
                dict(role='user', content='go'),
                dict(role='assistant', content=None, tool_calls=[{'function': {'name': 'PowerShell'}}]),
                dict(role='tool', content='ok'),
            ]))
            store = root / '.doubao-store'
            store.mkdir()
            now_ms = int((time.time() + 2) * 1000)
            (store / '000004.log').write_text(json.dumps({
                'closed': True, 'closedThroughSeq': '6',
                'identity': {'agentId': 'a', 'conversationId': 'conv-1'}, 'updatedAt': now_ms,
            }))
            with isolated_home(root):
                result = scan(root, root / 'cache.json')['豆包']
            self.assertEqual(result['Sessions'][0]['State'], 'complete')
            # A closed state older than the last trajectory event is a previous turn.
            (store / '000004.log').write_text(json.dumps({
                'closed': True, 'identity': {'agentId': 'a', 'conversationId': 'conv-1'},
                'updatedAt': now_ms - 600000,
            }))
            with isolated_home(root):
                self.assertEqual(scan(root, root / 'cache.json')['豆包']['Sessions'][0]['State'], 'thinking')
            self.assertEqual(read_doubao_runs(store)['conv-1']['Closed'], True)

    def test_scan_reads_doubao_trajectories(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / "data") as tmp:
            root = Path(tmp)
            agent = root / '.doubao-sessions' / 'conversation' / 'agents' / 'worker' / 'system'
            agent.mkdir(parents=True)
            (agent / 'trajectory.jsonl').write_text('\n'.join(json.dumps(e) for e in [
                dict(role='user', content='go'),
                dict(role='assistant', content=None, tool_calls=[{'function': {'name': 'PowerShell'}}]),
            ]))
            with isolated_home(root):
                result = scan(root, root / 'cache.json')['豆包']
            self.assertEqual([s['State'] for s in result['Sessions']], ['tool'])
            self.assertEqual(result['Sessions'][0]['Id'], 'worker')
            self.assertEqual(result['Usage'], [])
            self.assertGreater(result['Sessions'][0]['Time'], time.time() - 60)

    def test_newest_generation_only_and_cache_staleness(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / "data") as tmp:
            root = Path(tmp)
            logs = root / '.dsh/sessions/work/session-one'
            logs.mkdir(parents=True)
            import time
            event = dict(type='turn/start', time=time.time())
            for version in (3, 4):
                (logs / f'session.v{version}.jsonl').write_text(json.dumps(event))
            with isolated_home(root):
                result = scan(root, root / 'cache.json')['DeepSeek Harness']
            self.assertEqual(len(result['Sessions']), 1)
            self.assertEqual(result['Sessions'][0]['State'], 'thinking')
            cache = json.loads((root / 'cache.json').read_text())
            for item in cache.values():
                item['Info']['Time'] = time.time() - 700
            (root / 'cache.json').write_text(json.dumps(cache))
            with isolated_home(root):
                self.assertEqual(scan(root, root / 'cache.json')['DeepSeek Harness']['Sessions'][0]['State'], 'unknown')


    def test_harness_context_usage(self):
        usage = {'inputTokens': 100, 'cacheReadTokens': 900, 'outputTokens': 50}
        events = [
            dict(type='model/selection', seq=1, time=1000, data={'provider': 'deepseek-official', 'model': 'deepseek-flash'}),
            dict(type='request/context', seq=2, time=1001, data={'provider': 'deepseek-official', 'model': 'deepseek-flash', 'contextWindow': 1000000}),
            dict(type='assistant/message', seq=3, time=1002, data={'message': {'id': 'm1'}, 'usage': usage}),
            dict(type='assistant/message', seq=4, time=1003, data={'message': {'id': 'm2'}, 'usage': dict(usage, inputTokens=50, cacheReadTokens=950, outputTokens=20)}),
        ]
        actual = parse_events(events, 'DeepSeek Harness', 1004)
        self.assertEqual(actual['Context'], dict(Tokens=1000, Cached=950, Output=20, Window=1000000,
                                                 Model='deepseek-flash', Provider='deepseek-official', HasUsage=True))
        self.assertNotIn('Context', parse_events(events, 'Claude', 1004))
        self.assertEqual(parse_events([dict(type='turn/start', time=1000)], 'DeepSeek Harness', 1001)['Context']['Window'], 0)

    def test_scan_reports_harness_context_and_refreshes_old_cache(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / "data") as tmp:
            root = Path(tmp)
            logs = root / '.dsh/sessions/work/session-one'
            logs.mkdir(parents=True)
            import time
            now = time.time()
            events = [
                dict(type='session', version=4, id='s1', createdAt=int(now * 1000)),
                dict(type='model/selection', seq=1, time=1000, data={'provider': 'deepseek-official', 'model': 'deepseek-flash'}),
                dict(type='request/context', seq=2, time=1001, data={'contextWindow': 1000000}),
                dict(type='turn/start', seq=3, time=1002),
                dict(type='assistant/message', seq=4, time=1003, data={'message': {'id': 'm1'}, 'usage': {'inputTokens': 10, 'cacheReadTokens': 90, 'outputTokens': 5}}),
            ]
            (logs / 'session.v4.jsonl').write_text('\n'.join(json.dumps(e) for e in events))
            with isolated_home(root):
                result = scan(root, root / 'cache.json')['DeepSeek Harness']
            self.assertEqual(result['Context']['Window'], 1000000)
            self.assertEqual(result['Context']['Model'], 'deepseek-flash')
            self.assertEqual(result['Sessions'][0]['Context']['Tokens'], 100)
            # Caches written before this feature must be reparsed instead of shown empty.
            cache = json.loads((root / 'cache.json').read_text())
            for item in cache.values():
                item['Info'].pop('Context', None)
            (root / 'cache.json').write_text(json.dumps(cache))
            with isolated_home(root):
                refreshed = scan(root, root / 'cache.json')['DeepSeek Harness']
            self.assertEqual(refreshed['Context']['Window'], 1000000)

    def test_workbuddy_lifecycle_usage_and_privacy(self):
        import time
        now = time.time()

        def event(kind, **fields):
            return dict(type=kind, timestamp=int(now * 1000), **fields)

        usage = dict(inputTokens=100, outputTokens=20, totalTokens=120,
                     inputTokensDetails=[dict(cached_tokens=60)])
        events = [
            event('session-meta'),
            event('message', role='user', content=[{'type': 'text', 'text': 'secret prompt'}]),
            event('reasoning', content='secret reasoning'),
            event('function_call', id='step-1', name='Bash', arguments='secret args',
                  providerData=dict(requestModelName='hy4-free', conversationRequestId='r1',
                                    usage=usage,
                                    rawUsage=dict(quota=dict(percent=12, reset_at='1794546108')))),
        ]
        info = parse_workbuddy(events, now)
        self.assertEqual(info['State'], 'tool')
        self.assertEqual(info['Usage'], dict(Input=100, Cached=60, Output=20, Total=120))
        self.assertEqual(info['Context'], dict(Tokens=100, Cached=60, Output=20, Window=0,
                                               Model='hy4-free', Provider='', HasUsage=True))
        self.assertEqual(info['Quota']['used_percent'], 12)
        self.assertTrue(asks_user('AskUserQuestion'))
        self.assertFalse(asks_user('Bash'))
        # Repeated record ids must not double-count cached input.
        self.assertEqual(parse_workbuddy(events + [events[-1]], now)['Usage']['Total'], 120)
        events.append(event('function_call', id='step-2', name='AskUserQuestion'))
        self.assertEqual(parse_workbuddy(events, now)['State'], 'action')
        events.append(event('function_call_result', status='completed', name='AskUserQuestion'))
        self.assertEqual(parse_workbuddy(events, now)['State'], 'thinking')
        events.append(event('message', role='assistant', status='completed'))
        self.assertEqual(parse_workbuddy(events, now)['State'], 'complete')
        events.append(event('message', role='assistant', status='incomplete'))
        self.assertEqual(parse_workbuddy(events, now)['State'], 'unknown')
        self.assertEqual(parse_workbuddy([event('function_call', name='Bash')], now + 700)['State'], 'unknown')
        emitted = json.dumps(parse_workbuddy(events, now), ensure_ascii=False)
        for secret in ('secret prompt', 'secret reasoning', 'secret args'):
            self.assertNotIn(secret, emitted)

    def test_scan_reads_workbuddy_sessions_context_and_quota(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            folder = root / '.workbuddy' / 'projects' / 'proj'
            folder.mkdir(parents=True)
            now = int(time.time() * 1000)
            events = [
                dict(type='session-meta', timestamp=now),
                dict(type='message', role='user', timestamp=now + 1),
                dict(type='function_call', id='c1', name='Read', timestamp=now + 2,
                     providerData=dict(requestModelName='hy4-free', conversationRequestId='r1',
                                       usage=dict(inputTokens=100, outputTokens=10, totalTokens=110,
                                                  inputTokensDetails=[dict(cached_tokens=40)]),
                                       rawUsage=dict(quota=dict(percent=25, reset_at='1794546108')))),
                dict(type='function_call_result', status='completed', timestamp=now + 3),
                dict(type='message', role='assistant', status='completed', timestamp=now + 4),
            ]
            (folder / 'session.jsonl').write_text('\n'.join(json.dumps(e) for e in events), encoding='utf-8')
            with isolated_home(root):
                result = scan(root, root / 'cache.json')['WorkBuddy']
            self.assertEqual(result['Sessions'][0]['State'], 'complete')
            self.assertEqual(result['Usage'][0]['Agent'], 'WorkBuddy')
            self.assertEqual(result['Usage'][0]['Total'], 110)
            self.assertEqual(result['Usage'][0]['Cached'], 40)
            self.assertEqual(result['Context']['Model'], 'hy4-free')
            self.assertEqual(result['Quota']['primary']['used_percent'], 25)
            self.assertEqual(result['Quota']['primary']['window_label'], 'WorkBuddy 模型额度')
            self.assertEqual(result['Quota']['primary']['window_minutes'], 0)

    def test_workbuddy_fast_channel_tail_and_cache(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            folder = root / '.workbuddy' / 'projects' / 'proj'
            folder.mkdir(parents=True)
            log = folder / 'session.jsonl'
            cache = {}
            with isolated_home(root):
                for kind, expected in [('function_call', 'tool'),
                                       ('function_call_result', 'thinking'),
                                       ('message', 'complete')]:
                    record = dict(type=kind, timestamp=int(time.time() * 1000))
                    if kind == 'function_call':
                        record.update(name='Bash')
                    if kind == 'function_call_result':
                        record.update(status='completed')
                    if kind == 'message':
                        record.update(role='assistant', status='completed')
                    with log.open('a', encoding='utf-8') as handle:
                        handle.write(json.dumps(record) + '\n')
                    detail = scan_workbuddy_fast(root, cache, time.time())
                    self.assertEqual(detail['Sessions'][0]['State'], expected)
                    self.assertEqual(scan_workbuddy_fast(root, cache, time.time()), detail)
                # A log larger than the tail budget still reports the newest event.
                with log.open('a', encoding='utf-8') as handle:
                    handle.write(json.dumps(dict(type='ai-title', padding='x' * 300000)) + '\n')
                    handle.write(json.dumps(dict(type='function_call', name='Bash',
                                                 timestamp=int(time.time() * 1000))) + '\n')
                self.assertEqual(scan_workbuddy_fast(root, cache, time.time())['Sessions'][0]['State'], 'tool')

    def test_harness_fast_warns_when_zstd_decoder_missing(self):
        import time
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            folder = root / '.dsh/sessions/work/session-one'
            folder.mkdir(parents=True)
            (folder / 'session.v4.jsonl.zstd').write_bytes(b'(\xb5/\xfd\x00')
            with isolated_home(root), mock.patch('AgentTelemetry.read_events',
                                                side_effect=ImportError('decoder missing')):
                result = scan_harness_fast(root, {}, time.time())
            # An empty session list used to look like "no work" and froze the
            # brand at online, silently removing every completion animation.
            self.assertEqual(result['Sessions'], [])
            self.assertIn('decoder missing', result['Warning'])

    def test_harness_fast_reads_compressed_session_lifecycle(self):
        import time
        now = time.time()
        events = [dict(type='turn/start', time=now, data={}),
                  dict(type='tool/call', time=now + 1, data={}),
                  dict(type='turn/end', time=now + 2,
                       data={'reason': {'kind': 'completed'}})]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'data') as tmp:
            root = Path(tmp)
            folder = root / '.dsh/sessions/work/session-one'
            folder.mkdir(parents=True)
            (folder / 'session.v4.jsonl.zstd').write_bytes(b'(\xb5/\xfd\x00')
            with isolated_home(root), mock.patch('AgentTelemetry.read_events',
                                                return_value=iter(events)):
                result = scan_harness_fast(root, {}, now)
            self.assertEqual([s['State'] for s in result['Sessions']], ['complete'])
            self.assertNotIn('Warning', result)

    def test_read_events_routes_zstd_files_through_decoder(self):
        import io
        from AgentTelemetry import read_events
        payload = io.StringIO('{"type":"turn/start","time":1}\n')
        with mock.patch('AgentTelemetry.open_zstd_text', return_value=payload) as opener:
            events = list(read_events(Path('session.v4.jsonl.zstd')))
        self.assertTrue(opener.called)
        self.assertEqual(events[0]['type'], 'turn/start')


if __name__ == '__main__':
    unittest.main()
