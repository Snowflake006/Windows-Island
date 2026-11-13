$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'VpnStatus.ps1')
# Local protocol fixtures only. No installed clients, config files or Internet.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class IslandMihomoTestServer : IDisposable {
 TcpListener tcp; NamedPipeServerStream pipe; Stream active; Thread worker;
 volatile bool stopped; public int Port; public string PipeName;
 public IslandMihomoTestServer(bool named) {
  if(named) { PipeName="Island-Mihomo-fixture-"+Guid.NewGuid().ToString("N"); pipe=new NamedPipeServerStream(PipeName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous); }
  else { tcp=new TcpListener(IPAddress.Loopback,0); tcp.Start(); Port=((IPEndPoint)tcp.LocalEndpoint).Port; }
  worker=new Thread(Run); worker.IsBackground=true; worker.Start();
 }
 void Run() {
  while(!stopped) {
   try {
    if(pipe!=null) { pipe.WaitForConnection(); active=pipe; Respond(active); pipe.Disconnect(); }
    else { using(var client=tcp.AcceptTcpClient()) { active=client.GetStream(); active.ReadTimeout=2000; Respond(active); } }
   } catch { if(stopped) return; }
   finally { active=null; }
  }
 }
 void Respond(Stream stream) {
  var header=new StringBuilder();
  while(header.Length<32768) { int value=stream.ReadByte(); if(value<0)return; header.Append((char)value); if(header.ToString().EndsWith("\r\n\r\n"))break; }
  string request=header.ToString();
  bool authorized=request.Contains("Authorization: Bearer fixture-bearer\r\n");
  if(request.StartsWith("GET /slow "))Thread.Sleep(2100);
  string body=authorized ? "{\"meta\":true,\"version\":\"Mihomo-fixture\",\"label\":\"\u6d4b\u8bd5\u8282\u70b9\"}" : "{}";
  byte[] payload=Encoding.UTF8.GetBytes(body);
  bool chunked=request.StartsWith("GET /chunk ");
  string response="HTTP/1.1 "+(authorized?"200 OK":"401 Unauthorized")+"\r\nConnection: close\r\n"+(chunked?"Transfer-Encoding: chunked":"Content-Length: "+payload.Length)+"\r\n\r\n";
  byte[] head=Encoding.ASCII.GetBytes(response); stream.Write(head,0,head.Length);
  if(chunked) {
   int split=payload.Length-5;
   WriteChunk(stream,payload,0,split); WriteChunk(stream,payload,split,payload.Length-split);
   byte[] end=Encoding.ASCII.GetBytes("0\r\n\r\n");stream.Write(end,0,end.Length);
  } else stream.Write(payload,0,payload.Length);
  stream.Flush();
 }
 static void WriteChunk(Stream stream,byte[] bytes,int offset,int count) {
  byte[] head=Encoding.ASCII.GetBytes(count.ToString("x")+"\r\n");stream.Write(head,0,head.Length);stream.Write(bytes,offset,count);stream.Write(new byte[]{13,10},0,2);
 }
 public void Dispose() { stopped=true; try{if(tcp!=null)tcp.Stop();}catch{} try{if(pipe!=null)pipe.Dispose();}catch{} try{if(active!=null)active.Dispose();}catch{} worker.Join(3000); }
}
'@
$checks=0
foreach ($named in @($false,$true)) {
 $server=[IslandMihomoTestServer]::new($named)
 try {
  $controller=if($named){New-IslandMihomoController ('\\.\pipe\'+$server.PipeName) 'fixture-bearer' -Pipe}else{New-IslandMihomoController ('127.0.0.1:'+$server.Port) 'fixture-bearer'}
  $result=Invoke-IslandMihomo $controller '/version'
  if (!$result.meta) { throw 'Authenticated version request failed' }; $checks++
  if ($named -and $controller.OwnerId -ne $PID) { throw 'Named pipe server ownership failed' }; $checks++
  $result=Invoke-IslandMihomo $controller '/chunk'
  $expected=([char]0x6d4b).ToString()+([char]0x8bd5)+([char]0x8282)+([char]0x70b9)
  if ($result.label -ne $expected) { throw 'UTF-8 chunked response failed' }; $checks++
  $controller.Secret='wrong-fixture-key'; $rejected=$false
  try { $null=Invoke-IslandMihomo $controller '/version' } catch { $rejected=$true }
  if (!$rejected) { throw 'Authentication failure was ignored' }; $checks++
  $controller.Secret='fixture-bearer'; $timedOut=$false; $watch=[Diagnostics.Stopwatch]::StartNew()
  try { $null=Invoke-IslandMihomo $controller '/slow' } catch { $timedOut=$true }
  if (!$timedOut -or $watch.ElapsedMilliseconds -gt 3500) { throw 'Controller timeout is not bounded' }; $checks++
 } finally { $server.Dispose() }
}
'PASS: '+$checks+' local transport checks; HTTP/pipe authentication, server PID, UTF-8 chunks, 401 rejection and bounded timeouts'
