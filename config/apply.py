#!/usr/bin/env python3
"""Apply Hindsight bank configuration idempotently.

Usage:
    python apply.py personal [--alias NAME] [--dry-run] [--force]
    python apply.py shared [--dry-run] [--force]
    python apply.py --list
"""

import argparse
import getpass
import os
import sys

# Add the config directory to path for bank imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

API_URL = os.environ.get("HINDSIGHT_API_URL")
API_TOKEN = os.environ.get("HINDSIGHT_API_TOKEN", "")


def main():
    global API_TOKEN
    parser = argparse.ArgumentParser(description="Apply Hindsight bank configuration")
    parser.add_argument("bank", nargs="?", choices=["personal", "shared"], help="Bank to configure")
    parser.add_argument("--alias", default=getpass.getuser(), help="User alias (default: current user)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be applied without making changes")
    parser.add_argument("--force", action="store_true", help="Skip confirmation prompts")
    parser.add_argument("--list", action="store_true", help="List available bank configs")
    args = parser.parse_args()

    if args.list:
        print("Available bank configurations:")
        print("  personal  - Personal memory bank (per-user)")
        print("  shared    - Team shared memory bank")
        return

    if not args.bank:
        parser.print_help()
        sys.exit(1)

    if not API_TOKEN:
        token_file = os.path.expanduser("~/.hindsight/token")
        if os.path.exists(token_file):
            with open(token_file) as f:
                token = f.read().strip()
            if token:
                os.environ["HINDSIGHT_API_TOKEN"] = token
                API_TOKEN = token
                print(f"  Using cached token from {token_file}")

    if not API_TOKEN:
        print("Error: HINDSIGHT_API_TOKEN not set.", file=sys.stderr)
        print("Run ./hindsight-auth.sh first, then: export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token)", file=sys.stderr)
        sys.exit(1)

    if not API_URL:
        print("Error: HINDSIGHT_API_URL not set.", file=sys.stderr)
        print("Set it to your Hindsight API endpoint, e.g.:", file=sys.stderr)
        print('  export HINDSIGHT_API_URL="https://<your-domain>"', file=sys.stderr)
        sys.exit(1)

    # Lazy import after token check — the SDK may not be installed
    try:
        from hindsight_client import Hindsight
    except ImportError:
        print("Error: hindsight-client not installed. Run: ./setup-venv.sh", file=sys.stderr)
        sys.exit(1)

    client = Hindsight(base_url=API_URL, api_key=API_TOKEN)

    if args.bank == "personal":
        from banks.personal import CONFIG, DIRECTIVES, MENTAL_MODELS
        bank_id = args.alias
        # Replace {alias} placeholder in config values
        config = {k: v.replace("{alias}", args.alias) if isinstance(v, str) else v for k, v in CONFIG.items()}
    else:
        from banks.shared import CONFIG, DIRECTIVES, MENTAL_MODELS
        bank_id = "shared"
        config = CONFIG.copy()

    print(f"{'[DRY RUN] ' if args.dry_run else ''}Applying config to bank: {bank_id}")
    print(f"  API URL: {API_URL}")
    print()

    # 1. Apply bank config (create_bank is idempotent PUT + update_bank_config for entity_labels)
    _apply_config(client, bank_id, config, args.dry_run)

    # 2. Sync directives
    _sync_directives(client, bank_id, DIRECTIVES, args.dry_run, args.force)

    # 3. Ensure mental models exist
    _ensure_mental_models(client, bank_id, MENTAL_MODELS, args.dry_run)

    print()
    print("Done!" if not args.dry_run else "[DRY RUN] No changes made.")


def _apply_config(client, bank_id, config, dry_run):
    """Apply bank configuration (idempotent).

    Uses create_bank (PUT) for bank-level fields (name, missions, dispositions)
    and update_bank_config for config-only fields (entity_labels, etc).
    """
    print("  Applying bank config...")
    if dry_run:
        for k, v in config.items():
            val_preview = str(v)[:60] + "..." if len(str(v)) > 60 else str(v)
            print(f"    {k} = {val_preview}")
        return

    # Fields supported by create_bank (PUT /v1/default/banks/{bank_id})
    bank_fields = {
        "name", "retain_mission", "reflect_mission", "observations_mission",
        "retain_extraction_mode", "retain_custom_instructions", "retain_chunk_size",
        "enable_observations", "disposition_skepticism", "disposition_literalism",
        "disposition_empathy",
    }

    # Fields that must go through update_bank_config
    config_only_fields = {"entity_labels", "entities_allow_free_form", "retain_strategies",
                          "retain_default_strategy", "mcp_enabled_tools"}

    # Split config into the two calls
    bank_kwargs = {k: v for k, v in config.items() if k in bank_fields}
    config_kwargs = {k: v for k, v in config.items() if k in config_only_fields}

    # Apply bank-level fields via create_bank (idempotent PUT)
    if bank_kwargs:
        client.create_bank(bank_id, **bank_kwargs)
        print("    Done: bank profile updated")

    # Apply config-only fields via update_bank_config
    if config_kwargs:
        client.update_bank_config(bank_id, **config_kwargs)
        print("    Done: bank config updated")

    if not bank_kwargs and not config_kwargs:
        print("    No config changes to apply")


def _sync_directives(client, bank_id, desired, dry_run, force):
    """Sync directives: create missing, delete extra, recreate changed."""
    print("  Syncing directives...")

    if dry_run:
        for d in desired:
            print(f"    Desired: {d['name']}")
        print("    (run without --dry-run to sync against live state)")
        return

    response = client.list_directives(bank_id)
    existing = response.items

    existing_by_name = {d.name: d for d in existing}
    desired_by_name = {d["name"]: d for d in desired}

    # Create missing
    to_create = [d for name, d in desired_by_name.items() if name not in existing_by_name]
    # Delete extra
    to_delete = [d for name, d in existing_by_name.items() if name not in desired_by_name]
    # Recreate changed (content mismatch)
    to_recreate = []
    for name, desired_d in desired_by_name.items():
        if name in existing_by_name and existing_by_name[name].content != desired_d["content"]:
            to_recreate.append((existing_by_name[name], desired_d))

    if not to_create and not to_delete and not to_recreate:
        print("    Directives already in sync")
        return

    for d in to_create:
        print(f"    + Create: {d['name']}")
        if not dry_run:
            client.create_directive(bank_id, name=d["name"], content=d["content"],
                                    priority=d.get("priority", 0))

    for existing_d, desired_d in to_recreate:
        print(f"    ~ Recreate (content changed): {desired_d['name']}")
        if not dry_run:
            client.delete_directive(bank_id, directive_id=existing_d.id)
            client.create_directive(bank_id, name=desired_d["name"], content=desired_d["content"],
                                    priority=desired_d.get("priority", 0))

    for d in to_delete:
        if not force:
            print(f"    - Would delete: {d.name} (use --force to confirm)")
        else:
            print(f"    - Delete: {d.name}")
            if not dry_run:
                client.delete_directive(bank_id, directive_id=d.id)


def _ensure_mental_models(client, bank_id, desired, dry_run):
    """Ensure mental models exist (create missing, skip existing)."""
    print("  Ensuring mental models...")

    if dry_run:
        for model in desired:
            print(f"    Desired: {model['name']}")
        print("    (run without --dry-run to sync against live state)")
        return

    response = client.list_mental_models(bank_id)
    existing = response.items
    existing_names = {m.name for m in existing}

    for model in desired:
        if model["name"] in existing_names:
            print(f"    Exists: {model['name']}")
        else:
            print(f"    + Create: {model['name']}")
            if not dry_run:
                client.create_mental_model(
                    bank_id,
                    name=model["name"],
                    source_query=model["source_query"],
                    trigger={"refresh_after_consolidation": True},
                )


if __name__ == "__main__":
    main()
