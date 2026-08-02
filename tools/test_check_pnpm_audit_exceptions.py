import unittest

import check_pnpm_audit_exceptions as checker


class AuditPolicyTest(unittest.TestCase):
    def test_blocks_all_high_and_critical_vulnerabilities(self):
        self.assertTrue(checker.is_blocking("high", False))
        self.assertTrue(checker.is_blocking("critical", False))

    def test_blocks_moderate_only_for_direct_production_dependency(self):
        self.assertTrue(checker.is_blocking("moderate", True))
        self.assertFalse(checker.is_blocking("moderate", False))

    def test_advisory_paths_distinguish_direct_and_transitive_findings(self):
        data = {
            "advisories": {
                "1": {
                    "module_name": "direct-package",
                    "severity": "moderate",
                    "github_advisory_id": "GHSA-direct",
                    "findings": [{"paths": [".>direct-package"]}],
                },
                "2": {
                    "module_name": "transitive-package",
                    "severity": "moderate",
                    "github_advisory_id": "GHSA-transitive",
                    "findings": [
                        {"paths": [".>parent-package>transitive-package"]}
                    ],
                },
            }
        }

        vulnerabilities = list(checker.iter_vulns(data))

        self.assertTrue(vulnerabilities[0][4])
        self.assertFalse(vulnerabilities[1][4])

    def test_rejects_placeholder_exception_owners(self):
        self.assertTrue(checker.is_placeholder_owner("security@your-domain"))
        self.assertTrue(checker.is_placeholder_owner("TODO"))
        self.assertFalse(checker.is_placeholder_owner("JayHome137"))


if __name__ == "__main__":
    unittest.main()
