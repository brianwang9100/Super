import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from capture import prepare_project


class IsolatedProjectTests(unittest.TestCase):
    def test_generation_preserves_open_project_and_rebases_package_schemes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'Super.xcodeproj/project.pbxproj'
            original.parent.mkdir()
            original.write_text('local signing edits')
            schemes = root / 'Scripts/xcodegen-extras'
            schemes.mkdir(parents=True)
            source = schemes / 'Core.xcscheme'
            source.write_text('<BuildableReference ReferencedContainer="container:Packages/Core"/>')

            def generate(args, **kwargs):
                spec = json.loads(Path(args[args.index('--spec') + 1]).read_text())
                self.assertEqual(spec['include'], [str(root / 'project.yml')])
                self.assertEqual(spec['options']['postGenCommand'], '')
                self.assertEqual(args[args.index('--project-root') + 1], str(root))
                destination = Path(args[args.index('--project') + 1])
                self.assertNotEqual(destination, root)
                (destination / 'Super.xcodeproj').mkdir()

            with patch('capture.subprocess.run', side_effect=generate):
                project = prepare_project(root, root / '.build/VisualTesting')
            scheme = project / 'xcshareddata/xcschemes/Core.xcscheme'
            self.assertIn('container:../../../Packages/Core', scheme.read_text())
            self.assertEqual(original.read_text(), 'local signing edits')
            self.assertIn('container:Packages/Core', source.read_text())
