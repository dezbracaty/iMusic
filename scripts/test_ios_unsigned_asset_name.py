"""Check the iOS bundle version and unsigned IPA naming contract."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


class UnsignedAssetNameTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[1]
    text = (root / '.github/workflows/ios-release.yml').read_text(encoding='utf-8')
    steps = {step['name']: step for step in yaml.safe_load(text)['jobs']['build']['steps']}

    def test_all_asset_steps_use_the_display_version(self):
        steps = self.steps
        for name in ('Package unsigned IPA', 'Inspect IPA contents'):
            self.assertIn('imusic_ios_${RELEASE_VERSION}.ipa', steps[name]['run'])
            self.assertEqual(steps[name]['env']['RELEASE_VERSION'], '${{ steps.version.outputs.display_version }}')
        upload = steps['Upload IPA']['with']['path']
        self.assertTrue(upload.endswith('imusic_ios_${{ steps.version.outputs.display_version }}.ipa'))
        self.assertEqual(steps['Attach IPA to GitHub release']['with']['files'], upload)
        inspect = steps['Inspect IPA contents']
        self.assertIn('python3 ../../../scripts/verify_ios_ipa.py', inspect['run'])
        self.assertIn('--expected-version "$EXPECTED_VERSION"', inspect['run'])
        self.assertEqual(inspect['env']['EXPECTED_VERSION'], '${{ steps.version.outputs.marketing_version }}')
        self.assertIn('--expected-bundle-id com.jiajia2222.imusic.ios', inspect['run'])

    def test_development_and_tagged_versions_resolve_separately(self):
        fixtures = [
            ('refs/heads/dev', 'dev', '1', '2.1.0', '2.1-dev', '215'),
            ('refs/tags/v2.1', 'v2.1', '255', '2.1.0', '2.1', '255'),
            ('refs/tags/v2.1.3-rc1', 'v2.1.3-rc1', '256', '2.1.3', '2.1.3-rc1', '256'),
        ]
        for ref, name, run, version, label, build in fixtures:
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'github-output'
                env = dict(os.environ, GITHUB_REF=ref, GITHUB_REF_NAME=name,
                           GITHUB_RUN_NUMBER=run, GITHUB_OUTPUT=str(output))
                subprocess.run(['bash', '-c', self.steps['Resolve release version']['run']],
                               env=env, cwd=self.root, check=True, capture_output=True)
                self.assertEqual(dict(line.split('=', 1) for line in output.read_text().splitlines()), {
                    'marketing_version': version,
                    'display_version': label,
                    'build_number': build,
                })


if __name__ == '__main__':
    unittest.main()
