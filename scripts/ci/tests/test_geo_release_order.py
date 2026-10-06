"""Control-plane contract: reviewed content -> Portal assets -> frontend router."""

from pathlib import Path
import unittest

import yaml


class GeoReleaseOrderTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[3]
        workflow = root / ".github/workflows/serverless-orchestrator.yml"
        self.workflow = yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)

    def test_router_waits_for_successful_portal_asset_publication(self):
        router = self.workflow["jobs"]["frontend_router"]
        self.assertIn("static_pages", router["needs"])
        self.assertIn("needs.static_pages.result == 'success'", router["if"])

    def test_website_content_ref_is_shared_by_ssr_and_static_builds(self):
        inputs = self.workflow["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["website_content_ref"]["default"], "main")
        for job in ("cloudflare_ssr", "static_pages"):
            steps = self.workflow["jobs"][job]["steps"]
            deploy = next(step for step in steps if step.get("env", {}).get("CLOUDFLARE_TARGET") in ("ssr", "static-pages"))
            self.assertEqual(deploy["env"]["WEBSITE_CONTENT_REF"], "${{ inputs.website_content_ref || 'main' }}")

    def test_dependency_graph_is_acyclic(self):
        jobs = self.workflow["jobs"]
        visited, active = set(), set()

        def visit(name):
            self.assertNotIn(name, active)
            if name in visited:
                return
            active.add(name)
            needs = jobs[name].get("needs", [])
            if isinstance(needs, str):
                needs = [needs]
            for dependency in needs:
                visit(dependency)
            active.remove(name)
            visited.add(name)

        for name in jobs:
            visit(name)


if __name__ == "__main__":
    unittest.main()
