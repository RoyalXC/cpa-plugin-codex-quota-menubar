#!/usr/bin/env python3
"""Exercise the real CPA store installer in an isolated core and user data directory."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = 'codex-quota-menubar'


def free_port():
    with socket.socket() as channel:
        channel.bind(('127.0.0.1', 0))
        return channel.getsockname()[1]


def wait_for(check, timeout=20):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, KeyError) as error:
            last_error = error
        time.sleep(.1)
    raise RuntimeError('CPA smoke check did not complete' + (f' ({type(last_error).__name__})' if last_error else ''))


def helper_process(pid, home):
    """Check both PID and the private executable path, avoiding PID reuse."""
    output = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
    return str(home / 'payloads') in output and output.endswith('/Contents/MacOS/QuotaMenubar')


def smoke(core, artifact=None, registry_url=None, cpa_home=None):
    version = (ROOT / 'VERSION').read_text().strip()
    with tempfile.TemporaryDirectory(prefix='cpa-quota-smoke-') as directory:
        home = Path(directory).resolve()
        port = free_port()
        secret = secrets.token_urlsafe(32)
        plugin_home = home / 'widget'
        fake_cpa = home / 'cpa'
        (fake_cpa / 'oauth').mkdir(parents=True)
        plugin_dir = home / 'plugins'
        server = None
        if not registry_url:
            if not artifact:
                raise ValueError('--artifact or --registry-url is required')
            artifact = Path(artifact).resolve()
            data = artifact.read_bytes()
            arch = artifact.stem.rsplit('_', 1)[-1]
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path == '/registry.json':
                        body = json.dumps({'schema_version': 2, 'plugins': [{
                            'id': PLUGIN, 'name': 'Codex Quota Menubar', 'description': 'Isolated integration fixture',
                            'author': 'RoyalXC', 'version': version, 'install': {'type': 'direct', 'artifacts': [{
                                'goos': 'darwin', 'goarch': arch, 'url': registry_url.replace('/registry.json', '/plugin.zip'),
                                'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data),
                            }]},
                        }]}).encode()
                    elif self.path == '/plugin.zip':
                        body = data
                    else:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                def log_message(self, *args):
                    pass
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            registry_url = f'http://127.0.0.1:{server.server_port}/registry.json'
            threading.Thread(target=server.serve_forever, daemon=True).start()
        config = home / 'config.yaml'
        # JSON is valid YAML; this file contains only an ephemeral test key.
        config.write_text(json.dumps({
            'host': '127.0.0.1', 'port': port, 'auth-dir': str(fake_cpa / 'oauth'),
            'remote-management': {'secret-key': secret, 'allow-remote': False, 'disable-control-panel': True},
            'plugins': {'enabled': True, 'dir': str(plugin_dir), 'store-sources': [registry_url],
                        'store-auth': ([{'match': f'http://127.0.0.1:{server.server_port}/',
                                        'type': 'none', 'allow-insecure': True}] if server else []),
                        'configs': {PLUGIN: {'enabled': True, 'dataDir': str(plugin_home),
                                             'cpaHome': str(Path(cpa_home).resolve() if cpa_home else fake_cpa),
                                             'managementPort': port}}},
        }))
        config.chmod(0o600)
        log = (home / 'core.log').open('wb')
        process = subprocess.Popen([str(Path(core).resolve()), '-config', str(config)], stdout=log, stderr=log)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def management(route, method='GET', body=None):
            request = urllib.request.Request(f'http://127.0.0.1:{port}/v0/management/{route}',
                data=json.dumps(body).encode() if body is not None else None, method=method,
                headers={'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'})
            with opener.open(request, timeout=20) as response:
                return json.load(response)
        def status():
            return json.loads((plugin_home / 'run/menubar/status.json').read_text())
        try:
            wait_for(lambda: management('plugins').get('plugins_enabled'))
            store = management('plugin-store')
            source = next((item for item in store['plugins'] if item['id'] == PLUGIN and item['source_url'] == registry_url), None)
            if source is None:
                raise RuntimeError('Test registry did not expose the plugin: ' + json.dumps(store.get('source_errors', [])))
            source_id = source['source_id']
            installed = management('plugin-store/' + PLUGIN + '/install?source=' + source_id, 'POST', {})
            entry = wait_for(lambda: next((item for item in management('plugins')['plugins']
                if item['id'] == PLUGIN and item.get('registered') and item.get('effective_enabled')), None))
            state = wait_for(lambda: status() if status().get('visible') else None)
            assert state.get('helperVersion') == version, 'Helper version mismatch'
            assert state.get('protocolVersion') == 2, 'Helper protocol mismatch'
            assert state.get('launchMode') == 'cpa-managed', 'Helper did not use ownership lifecycle'
            first_pid = state['pid']
            assert helper_process(first_pid, plugin_home), 'Unexpected helper process'
            management('plugins/' + PLUGIN + '/enabled', 'PATCH', {'enabled': False})
            wait_for(lambda: not helper_process(first_pid, plugin_home))
            management('plugins/' + PLUGIN + '/enabled', 'PATCH', {'enabled': True})
            resumed = wait_for(lambda: status() if status().get('pid') != first_pid else None)
            assert resumed['visible'] and resumed['helperVersion'] == version
            wait_for(lambda: status().get('quotaAvailable'), timeout=30) if cpa_home else None
            resumed = status()
            result = {'storeInstall': True, 'registered': True, 'statusItemVisible': True,
                      'disableEnable': True, 'helperVersion': version, 'protocolVersion': 2,
                      'quotaAvailable': resumed.get('quotaAvailable', False),
                      'source': 'public-registry' if not server else 'local-fixture',
                      'coreSHA256': hashlib.sha256(Path(core).read_bytes()).hexdigest(),
                      'installType': installed.get('install_type'),
                      'installedFile': Path(entry['path']).name}
            process.terminate()
            process.wait(timeout=10)
            wait_for(lambda: not helper_process(resumed['pid'], plugin_home))
            result['coreExitStopsHelper'] = True
            print(json.dumps(result, sort_keys=True))
            return result
        except Exception:
            log.flush()
            for line in (home / 'core.log').read_text(errors='replace').splitlines():
                if 'plugin' in line.lower() and any(word in line.lower() for word in ('failed', 'error', 'reject')):
                    print(line.replace(secret, '[REDACTED]'))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if server:
                server.shutdown()
                server.server_close()
            log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--core', required=True, type=Path)
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--registry-url')
    parser.add_argument('--cpa-home', type=Path, help='Optionally read an existing CPA account directory; never copied or changed')
    args = parser.parse_args()
    smoke(args.core, args.artifact, args.registry_url, args.cpa_home)
