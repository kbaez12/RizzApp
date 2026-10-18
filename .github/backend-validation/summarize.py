#!/usr/bin/env python3
"""Summarize backend validation: TypeScript drift vs known failures, and skipped hosted tests."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KNOWN_PATH = Path(__file__).resolve().parent / "deno-check-known-failures.txt"
OUT_DIR = Path(__file__).resolve().parent / "out"

ERROR_LINE = re.compile(
    r"^error:\s+(TS\d+)\s+\[ERROR\]:\s+(.*)$"
)
AT_LINE = re.compile(
    r"at\s+(?:file:///)?(?P<path>[^\s:]+):(?P<line>\d+):(?P<col>\d+)"
)


def repo_relative(raw_path: str) -> str:
    path = raw_path.replace("\\", "/")
    marker = "/supabase/functions/"
    if marker in path:
        return "supabase/functions/" + path.split(marker, 1)[1]
    if path.startswith("supabase/functions/"):
        return path
    return path.lstrip("/")


def parse_errors(text: str) -> set[str]:
    errors: set[str] = set()
    pending_code = ""
    pending_message = ""
    for raw in text.splitlines():
        line = raw.strip()
        match = ERROR_LINE.match(line)
        if match:
            pending_code, pending_message = match.group(1), match.group(2).strip()
            continue
        at = AT_LINE.search(line)
        if at and pending_code:
            rel = repo_relative(at.group("path"))
            errors.add(f"{pending_code} {rel} {pending_message}")
            pending_code = ""
            pending_message = ""
            continue
        if line.startswith("error:") and not pending_code:
            errors.add(line)
    if pending_code:
        errors.add(f"{pending_code} unknown {pending_message}")
    return errors


def load_known() -> set[str]:
    if not KNOWN_PATH.exists():
        return set()
    return {
        line.strip()
        for line in KNOWN_PATH.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def print_list(title: str, items: set[str]) -> None:
    print(f"\n{title} ({len(items)})")
    if not items:
        print("  (none)")
        return
    for item in sorted(items):
        print(f"  - {item}")


def report_skipped_integration() -> None:
    print("\n============================================================")
    print("HOSTED INTEGRATION TESTS — SKIPPED IN THIS WORKFLOW")
    print("============================================================")
    print(
        "These files need a running Supabase stack, JWTs, and/or live "
        "secrets. This workflow never sets those flags and never deploys."
    )
    print(
        """
SKIPPED  supabase/functions/tests/subscription_integration_test.ts
         Requires SUBSCRIPTION_INTEGRATION=true, USER_JWT, USER_ID,
         UNSUBSCRIBED_USER_JWT, PUBLISHABLE_KEY, and a hosted or local
         Edge Function stack. Covers live 401 JWT rejection, 402 for
         unsubscribed generate calls, and webhook duplicate/stale
         apply_revenuecat_event outcomes.

SKIPPED  supabase/functions/tests/integration_test.ts
         Legacy installation/free-tier suite. Requires
         LEGACY_INSTALLATION_INTEGRATION=true plus a pre-migration
         deployment. Not used for mandatory-subscription validation.

NOT RUN  supabase/functions/tests/quality_check.ts
         Manual quality harness. Spends real OpenAI calls. Never
         executed here.

NOT RUN  SQL RPCs in supabase/migrations/20261018000000_mandatory_subscriptions.sql
         reserve_user_usage / apply_revenuecat_event duplicate+stale
         protection needs Postgres. This workflow does not apply
         migrations or start Docker/Supabase.
"""
    )


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    shared_text = ""
    functions_text = ""
    shared_log = OUT_DIR / "deno-check-shared.txt"
    functions_log = OUT_DIR / "deno-check-functions.txt"
    if shared_log.exists():
        shared_text = shared_log.read_text(encoding="utf-8", errors="replace")
    if functions_log.exists():
        functions_text = functions_log.read_text(encoding="utf-8", errors="replace")

    current = parse_errors(shared_text) | parse_errors(functions_text)
    known = load_known()
    new_errors = current - known
    resolved = known - current
    still_known = current & known

    print("============================================================")
    print("TYPESCRIPT STATIC CHECK — NEW vs KNOWN")
    print("============================================================")
    print(f"Current errors: {len(current)}")
    print(f"Known baseline: {len(known)}")
    print_list("Known pre-existing failures still present", still_known)
    print_list("Resolved known failures", resolved)
    print_list("NEW TypeScript errors (fail the job)", new_errors)

    if shared_text.strip():
        print("\n----- deno check shared modules (raw) -----")
        print(shared_text.rstrip())
    if functions_text.strip():
        print("\n----- deno check Edge Function entrypoints (raw) -----")
        print(functions_text.rstrip())

    report_skipped_integration()

    fmt_log = OUT_DIR / "deno-fmt.txt"
    if fmt_log.exists():
        fmt_text = fmt_log.read_text(encoding="utf-8", errors="replace")
        print("\n============================================================")
        print("DENO FORMAT CHECK (reported; does not fail this job)")
        print("============================================================")
        print(fmt_text.rstrip() or "(no formatter output)")

    if new_errors:
        print(
            "\nResult: FAILED — new TypeScript errors are not in "
            ".github/backend-validation/deno-check-known-failures.txt"
        )
        return 1

    if current:
        print(
            "\nResult: PASSED unit-test gate. TypeScript still has "
            f"{len(still_known)} known pre-existing failure(s)."
        )
    else:
        print("\nResult: PASSED — no TypeScript check errors.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
