"""Reviewed graph/closure tests; not a substitute for Apple compiler validation."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
SCRIPTS=Path(__file__).resolve().parents[1];ROOT=SCRIPTS.parent
spec=importlib.util.spec_from_file_location('impact_test',SCRIPTS/'ci-product-impact.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
GRAPH=json.loads((SCRIPTS/'ci-product-graph.json').read_text())
DI='InnoDI' in GRAPH['products']
class ProductImpactTests(unittest.TestCase):
 def test_manifest_digest_exact(self):
  self.assertEqual(GRAPH['manifest_sha256'],hashlib.sha256((ROOT/'Package.swift').read_bytes()).hexdigest());p.validate(GRAPH)
 def test_independent_product(self):
  name='InnoDISwiftUI' if DI else 'InnoNetworkAuthAWS';plan=p.select(GRAPH,['Sources/'+name+'/Changed.swift'])
  self.assertEqual(plan['mode'],'scoped-build-plan');self.assertEqual(plan['affected_products'],[name]);self.assertIn(name+'Tests',plan['affected_tests'])
  self.assertNotIn('InnoDI-Migrate' if DI else 'InnoNetworkDownload',plan['affected_products'])
 def test_shared_core_propagates_full(self):
  name='InnoDICore' if DI else 'InnoNetwork';plan=p.select(GRAPH,['Sources/'+name+'/Changed.swift']);self.assertEqual(plan['mode'],'full');self.assertEqual(set(plan['affected_products']),set(GRAPH['products']))
 def test_reverse_dependency_and_consumer(self):
  name='InnoDIMigrationCore' if DI else 'InnoNetworkDownload';plan=p.select(GRAPH,['Sources/'+name+'/Changed.swift'])
  self.assertIn('InnoDI-Migrate' if DI else 'InnoNetworkTestSupport',plan['affected_products'])
  self.assertIn('InnoDIMigrationCoreTests' if DI else 'InnoNetworkDownloadTests',plan['affected_tests'])
 def test_unknown_manifest_generated_resource_and_mixed_full(self):
  for paths in [['Package.swift'],['unknown.file'],['Sources/new/Changed.swift'],['Sources/'+('InnoDI' if DI else 'InnoNetwork')+'/Resources/file.json'],['Sources/'+('InnoDISwiftUI' if DI else 'InnoNetworkAuthAWS')+'/Foo.generated.swift'],['Sources/'+('InnoDISwiftUI' if DI else 'InnoNetworkAuthAWS')+'/Changed.swift','README.md'],[]]:
   with self.subTest(paths=paths):self.assertEqual(p.select(GRAPH,paths)['mode'],'full')
 def test_digest_mismatch_full(self):self.assertEqual(p.select(GRAPH,['Sources/'+('InnoDISwiftUI' if DI else 'InnoNetworkAuthAWS')+'/Changed.swift'],'0'*64)['mode'],'full')
 def test_native_builds_are_named_and_test_fallback_explicit(self):
  plan=p.select(GRAPH,['Sources/'+('InnoDISwiftUI' if DI else 'InnoNetworkAuthAWS')+'/Changed.swift'])
  self.assertTrue(plan['native_build_commands'])
  for command in plan['native_build_commands']:self.assertIn('--target',command);self.assertIn('--scratch-path',command)
  self.assertNotIn('--filter',plan['test_command']);self.assertIn('full package',plan['test_compilation_scope'])
 def test_unknown_dependency_cycle_and_unowned_path_reject(self):
  for dependency in ['Unknown',next(iter(GRAPH['targets']))]:
   graph=copy.deepcopy(GRAPH);name=next(iter(graph['targets']));graph['targets'][name]['dependencies'].append(dependency)
   with self.assertRaises(ValueError):p.validate(graph)
 def test_target_inventory_paths_exist(self):
  for name,target in GRAPH['targets'].items():
   for source in target['inputs']:self.assertTrue((ROOT/source).exists(),(name,source))
 def test_test_closure_is_not_confused_with_affected_products(self):
  name='InnoDITesting' if DI else 'InnoNetworkUpload';plan=p.select(GRAPH,['Sources/'+name+'/Changed.swift'])
  self.assertIn(name,plan['affected_products']);self.assertIn('InnoDI' if DI else 'InnoNetwork',plan['test_dependency_products'])
if __name__=='__main__':unittest.main()
