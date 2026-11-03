"""Check that local and VPS builds do not publish the GitHub Pages redirect."""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import build_supabase_site as common
import build_vps_preview as preview
import build_vps_production_candidate as candidate


class SiteBuildTests(unittest.TestCase):
    def test_all_builds_use_application_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'vps').mkdir()
            (root / 'vps/production-index.html').write_text('<main>application</main>', encoding='utf-8')
            (root / 'index.html').write_text('<meta http-equiv="refresh">', encoding='utf-8')
            (root / 'app-config.js').write_text('original', encoding='utf-8')
            (root / 'assets').mkdir()
            (root / 'map-data/tiles').mkdir(parents=True)
            (root / 'map-data/province-adjacency.json').write_text('{}', encoding='utf-8')
            public = ('index.html', 'app-config.js')
            with patch.object(common, 'ROOT', root), patch.object(common, 'PUBLIC', public), \
                 patch.object(preview, 'ROOT', root), patch.object(preview, 'PUBLIC', public), \
                 patch.object(candidate, 'ROOT', root), patch.object(candidate, 'PUBLIC', public), \
                 patch.object(candidate, 'TARGET', root / '.local/fauxlore-production-candidate'), \
                 contextlib.redirect_stdout(io.StringIO()):
                common.main()
                with patch.object(sys, 'argv', ['build_vps_preview.py', '--postgrest']):
                    preview.main()
                candidate.main()
                outputs = [root / '.local/supabase-site', candidate.TARGET,
                           next((root / '.local').glob('vps-preview-*'))]
                for output in outputs:
                    self.assertEqual((output / 'index.html').read_text(encoding='utf-8'), '<main>application</main>')
                self.assertIn("backend: 'vps-postgrest'", (candidate.TARGET / 'app-config.js').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
