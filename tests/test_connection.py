import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('connection', Path(__file__).resolve().parents[1]/'connection.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class ConnectionTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(module.parse('PROXY_PORT=1234\nPROXY_AUTH="user:abcd"\nTUNNEL_ID=sample')['PROXY_PORT'], '1234')
    def test_invalid(self):
        for text in ['PROXY_PORT=$(touch /tmp/no)', 'PROXY_PORT=70000\nPROXY_AUTH=user:abcd\nTUNNEL_ID=sample', 'PROXY_PORT=1\nPROXY_AUTH=user:abcd\nTUNNEL_ID=sample\nOTHER=1']:
            with self.assertRaises(ValueError): module.parse(text)
