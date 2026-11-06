"""CPU-only stalled-pipe regressions. No model or native backend is loaded."""
import json,os,pathlib,selectors,signal,subprocess,sys,tempfile,time,unittest
SUPERVISOR=pathlib.Path(__file__).with_name('supervise.py')
class SupervisorTests(unittest.TestCase):
    def launch(self,directory,ready):
        pidfile=pathlib.Path(directory)/'pid'
        fake=pathlib.Path(directory)/'fake-worker'
        fake.write_text('#!'+sys.executable+'\nimport os,time,signal,pathlib\npathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid()))\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n'+('print(\'{"event":"ready"}\',flush=True)\n' if ready else '')+'time.sleep(30)\n')
        fake.chmod(0o700)
        process=subprocess.Popen([sys.executable,str(SUPERVISOR),str(fake),'unused','0'*64,'--startup-deadline-ms','1000','--hard-grace-ms','50'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        return process,pidfile
    def assert_reaped(self,pidfile):
        pid=int(pidfile.read_text())
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
    def test_ready_worker_never_reads_large_frame(self):
        with tempfile.TemporaryDirectory() as directory:
            process,pidfile=self.launch(directory,True)
            selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
            self.assertTrue(selector.select(2));self.assertEqual(json.loads(process.stdout.readline())['event'],'ready');selector.close()
            large=(json.dumps({'op':'generate','id':'large','system':'s','user':'x'*900000,'deadline_ms':100})+'\n').encode()
            large+=(json.dumps({'op':'generate','id':'second','system':'s','user':'x','deadline_ms':100})+'\n').encode()
            start=time.monotonic();stdout,stderr=process.communicate(large,timeout=3)
            self.assertIn(b'busy',stdout)
            self.assertLess(time.monotonic()-start,2);self.assertNotEqual(process.returncode,0)
            self.assertIn(b'request/cancel deadline',stdout);self.assert_reaped(pidfile)
    def test_never_ready_rejects_generate_without_pipe_write(self):
        with tempfile.TemporaryDirectory() as directory:
            process,pidfile=self.launch(directory,False)
            large=(json.dumps({'op':'generate','id':'early','system':'s','user':'x'*900000,'deadline_ms':100})+'\n').encode()
            start=time.monotonic();stdout,stderr=process.communicate(large,timeout=3)
            self.assertLess(time.monotonic()-start,2.5);self.assertIn(b'not_ready',stdout)
            self.assertIn(b'readiness deadline',stdout);self.assert_reaped(pidfile)
    def test_unexpected_output_eof_reaps_live_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            fake=pathlib.Path(directory)/'fake-worker'
            pidfile=pathlib.Path(directory)/'pid'
            fake.write_text('#!'+sys.executable+'\nimport os,time,pathlib\npathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid()))\nprint(\'{"event":"ready"}\',flush=True)\nos.close(1)\ntime.sleep(30)\n')
            fake.chmod(0o700)
            process=subprocess.Popen([sys.executable,str(SUPERVISOR),str(fake),'unused','0'*64],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            start=time.monotonic()
            process.wait(timeout=3)
            stdout=process.stdout.read()
            self.assertLess(time.monotonic()-start,2)
            self.assertIn(b'unexpected worker stdout EOF',stdout)
            self.assert_reaped(pidfile)
            process.stdin.close();process.stdout.close();process.stderr.close()
    def test_correlated_error_allows_next_request(self):
        with tempfile.TemporaryDirectory() as directory:
            fake=pathlib.Path(directory)/'fake-worker'
            fake.write_text('#!'+sys.executable+'\nimport sys,json\nprint(\'{"event":"ready"}\',flush=True)\nfor line in sys.stdin:\n r=json.loads(line)\n if r["op"]=="shutdown":break\n print(json.dumps({"event":"error" if r["id"]=="bad" else "result","id":r["id"]}),flush=True)\n')
            fake.chmod(0o700)
            process=subprocess.Popen([sys.executable,str(SUPERVISOR),str(fake),'unused','0'*64],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
            def receive():
                self.assertTrue(selector.select(2));return json.loads(process.stdout.readline())
            self.assertEqual(receive()['event'],'ready')
            for bad_id in [[],{}]:
                process.stdin.write((json.dumps({'op':'cancel','id':bad_id})+'\n').encode());process.stdin.flush()
                self.assertEqual(receive()['error'],'invalid_id')
            for identity in ['bad','good']:
                process.stdin.write((json.dumps({'op':'generate','id':identity,'system':'s','user':'x','deadline_ms':100})+'\n').encode());process.stdin.flush()
                self.assertEqual(receive(),{'event':'error' if identity=='bad' else 'result','id':identity})
            process.stdin.write(b'{"op":"shutdown"}\n');process.stdin.flush();process.wait(timeout=2)
            self.assertEqual(process.returncode,0)
            selector.close();process.stdin.close();process.stdout.close();process.stderr.close()
    def test_owner_sigterm_reaps_separate_group(self):
        with tempfile.TemporaryDirectory() as directory:
            process,pidfile=self.launch(directory,True)
            selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
            self.assertTrue(selector.select(2));self.assertEqual(json.loads(process.stdout.readline())['event'],'ready');selector.close()
            start=time.monotonic();process.send_signal(signal.SIGTERM);process.wait(timeout=3)
            self.assertLess(time.monotonic()-start,2);self.assertNotEqual(process.returncode,0)
            self.assert_reaped(pidfile)
            process.stdin.close();process.stdout.close();process.stderr.close()
if __name__=='__main__':unittest.main()
