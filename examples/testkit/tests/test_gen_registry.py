from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import gen_registry as gen


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plugin = Path(self.temp.name)
        (self.plugin / 'src').mkdir()

    def source(self, text):
        path = self.plugin / 'src/Tests.as'
        path.write_text(text)
        return path

    def test_rewrite_namespaces_comments_multiline_and_same_line(self):
        path = self.source('''// [Test] void Fake(Tests::Context@ ctx) {}
string decoy = "[Test] void AlsoFake(Tests::Context@ ctx) {}";
namespace Outer { namespace Inner {
[Test] void One(Tests::Context@ ctx) { ctx.AssertTrue(true); }
[Test]
void Two(
    Tests::Context@ ctx
) {}
} }
namespace Tests { // [TestKit]
void Existing(TestKit::Ctx@ ctx) {}
}
''')
        cases = gen.generate(self.plugin, rewrite=True)
        self.assertEqual([c.name for c in cases], ['Outer::Inner::One', 'Outer::Inner::Two', 'Tests::Existing'])
        before = path.read_text()
        self.assertIn('TestKit::Ctx@ ctx', before)
        registry = (self.plugin / 'src/_TestRegistry.as').read_text()
        self.assertIn('::TestKit::Reg("Tests::Existing", ::Tests::Existing);', registry)
        self.assertIn('void TestKit_AllRegisteredTests(Tests::Context@ ctx)', registry)
        self.assertIn('::TestKit::RunAll(TestKit::CtxSink(ctx));', registry)
        gen.generate(self.plugin, rewrite=True)
        self.assertEqual(path.read_text(), before)
        self.assertEqual(registry, (self.plugin / 'src/_TestRegistry.as').read_text())
        self.assertEqual(len(gen.check_registry(self.plugin)), 3)

    def test_check_drift_does_not_write(self):
        self.source('// [TestKit]\nvoid One(TestKit::Ctx@ ctx) {}\n')
        gen.generate(self.plugin)
        registry = self.plugin / 'src/_TestRegistry.as'
        registry.write_text('stale')
        with self.assertRaises(gen.RegistryError):
            gen.check_registry(self.plugin)
        self.assertEqual(registry.read_text(), 'stale')

    def test_native_tests_require_explicit_rewrite(self):
        path = self.source('[Test] void One(Tests::Context@ ctx) {}')
        with self.assertRaises(gen.RegistryError):
            gen.generate(self.plugin)
        self.assertIn('[Test]', path.read_text())
        self.assertFalse((self.plugin / 'src/_TestRegistry.as').exists())

    def test_rejects_unsupported_duplicate_and_empty_unmarked_suite(self):
        for source in [
            '[Test(true)] void Wrong(Tests::Context@ ctx) {}',
            '[Test] int Wrong(Tests::Context@ ctx) {return 0;}',
            '[Test] void Wrong(Tests::Context@ ctx, int n) {}',
            'class C { [Test] void Method(Tests::Context@ ctx) {} }',
            '// [TestKit]\nvoid Wrong(Tests::Context@ ctx) {}',
            '// [TestKit]\nvoid One(TestKit::Ctx@ ctx) {}\n// [TestKit]\nvoid One(TestKit::Ctx@ ctx) {}',
            'void Missing(TestKit::Ctx@ ctx) {}',
        ]:
            with self.subTest(source=source):
                self.source(source)
                with self.assertRaises(gen.RegistryError):
                    gen.generate(self.plugin, rewrite=True)

    def test_fake_markers_in_block_comments_and_strings(self):
        self.source('''/* // [TestKit]\n[Test] void Nope(Tests::Context@ ctx) {} */
string fake = "// [TestKit]";
// [TestKit]
void Real(TestKit::Ctx@ ctx) { string braces = "} namespace False {"; }
''')
        self.assertEqual([c.name for c in gen.generate(self.plugin)], ['Real'])

    def test_global_callback_cannot_bind_to_testkit_namespace_shadow(self):
        self.source('// [TestKit]\nvoid Collision(TestKit::Ctx@ ctx) { ctx.AssertTrue(false); }\nnamespace TestKit {\n// [TestKit]\nvoid Collision(TestKit::Ctx@ ctx) { ctx.AssertTrue(true); }\n}\n')
        gen.generate(self.plugin)
        registry = (self.plugin / 'src/_TestRegistry.as').read_text()
        self.assertIn('::TestKit::Reg("Collision", ::Collision);', registry)
        self.assertIn('::TestKit::Reg("TestKit::Collision", ::TestKit::Collision);', registry)

    def test_empty_suite_rejected(self):
        self.source('void Main() {}')
        with self.assertRaises(gen.RegistryError):
            gen.generate(self.plugin)


if __name__ == '__main__':
    unittest.main()
