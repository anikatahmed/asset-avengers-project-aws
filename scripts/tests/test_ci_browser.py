"""Guard the real browser runner's isolation and artifact handling."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('browser_verifier', ROOT / 'scripts/verify-admin-stack.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class BrowserRunnerTests(unittest.TestCase):
    def test_container_version_network_and_secrets_are_scoped_to_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'internal-frontend').mkdir()
            (root / 'internal-frontend/package-lock.json').write_text(json.dumps({
                'packages': {'node_modules/@playwright/test': {'version': '1.64.1'}}}))
            calls = []
            def run(command, **kwargs):
                calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 1 if 'inspect' in command else 0)
            with patch.object(verifier, 'ROOT', root), patch.object(verifier.subprocess, 'check_output', return_value='temporary-auth-id'), patch.object(verifier.subprocess, 'run', side_effect=run):
                verifier.run_auth_browser(['docker', 'compose', '-p', 'test'], 'test', {})
            container, options = next(call for call in calls if call[0][:2] == ['docker', 'run'])
            self.assertIn('mcr.microsoft.com/playwright:v1.64.1-noble', container)
            self.assertIn('test_internal', container)
            self.assertIn('--rm', container)
            self.assertIn('--init', container)
            self.assertIn('TEST_LOGIN_PASSWORD', container)
            self.assertNotIn(options['env']['TEST_LOGIN_PASSWORD'], ' '.join(container))
            self.assertNotIn('docker.sock', ' '.join(container))
            self.assertNotIn('SUPERSET_SSO_SECRET', container)
            self.assertNotIn('JWT_SECRET', container)

    def test_ci_uses_real_auth_and_archives_browser_results(self):
        helper = (ROOT / 'scripts/ci-checks.sh').read_text()
        self.assertIn('--browser --auth-image "$auth_image"', helper)
        self.assertIn('unused-for-cleanup', helper)
        pipeline = (ROOT / 'Jenkinsfile').read_text()
        self.assertIn('Staff Integration and Browser Authentication', pipeline)
        self.assertIn('internal-frontend/test-results/browser/**/*.png', pipeline)
        self.assertIn('**/test-results/browser/junit.xml', pipeline)

    def test_authentication_test_does_not_inject_tokens_or_mock_http(self):
        test = (ROOT / 'internal-frontend/tests/auth-journey.e2e.ts').read_text()
        self.assertNotIn('page.route(', test)
        self.assertNotIn('useToken(', test)
        self.assertNotIn('Bearer ', test)
        self.assertIn('#mfa-secret', test)
        self.assertIn('sso-required', test)
        config = (ROOT / 'internal-frontend/playwright.ci.config.ts').read_text()
        self.assertIn("trace: 'off'", config)
        self.assertIn('mask:', test)
        self.assertNotIn('webServer:', config)


if __name__ == '__main__':
    unittest.main()
