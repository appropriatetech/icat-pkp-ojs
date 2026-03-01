#!/usr/bin/env python3

# pylint: disable=line-too-long
# flake8: noqa: E501

import argparse
import json
import subprocess
import sys
import os
import shutil


def main():
    parser = argparse.ArgumentParser(description="Submit a Cloud Build job for PKP OJS container.")
    parser.add_argument("--registry-uri", required=True, help="Artifact Registry URI")
    parser.add_argument("--tag", required=True, help="Image tag (e.g., timestamp)")
    parser.add_argument("--env-vars", required=True, help="JSON string of environment variables")
    parser.add_argument("--source-path", required=True, help="Path to container source code")
    parser.add_argument("--project-id", required=True, help="Google Cloud Project ID")
    parser.add_argument("--region", required=True, help="Google Cloud Region")
    parser.add_argument("--keep-config", action="store_true", help="Keep the generated Cloud Build config file")
    parser.add_argument("--no-submit", action="store_true", help="Generate config file but do not submit the build")

    args = parser.parse_args()

    # Resolve source path relative to current working directory
    source_path = os.path.abspath(args.source_path)
    if not os.path.exists(source_path):
        print(f"Error: Source path does not exist: {source_path}", file=sys.stderr)
        sys.exit(1)

    try:
        env_vars = json.loads(args.env_vars)
    except json.JSONDecodeError as e:
        print(f"Error parsing env-vars JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Copy email-relay scripts into build context
    email_relay_src = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', 'email-relay'))
    email_relay_dst = os.path.abspath(os.path.join(source_path, 'tools','email-relay'))
    email_relay_copied = False

    if not os.path.isdir(email_relay_src):
        print(f"Error: email-relay directory does not exist: {email_relay_src}", file=sys.stderr)
        sys.exit(1)

    shutil.copytree(
        email_relay_src, email_relay_dst,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns('__pycache__', '.pytest_cache', '.venv', 'tests'),
    )
    email_relay_copied = True
    print(f"Copied email-relay scripts to {email_relay_dst}")

    # Construct build arguments list
    build_args = []
    for k, v in env_vars.items():
        build_args.extend(["--build-arg", f"{k}={v}"])

    image_timestamp = f"{args.registry_uri}/icat-pkp-ojs:{args.tag}"
    image_latest = f"{args.registry_uri}/icat-pkp-ojs:latest"

    # Cloud Build configuration
    cloudbuild_config = {
        "steps": [
            {
                "name": "gcr.io/cloud-builders/docker",
                "args": [
                    "build",
                    "-t", image_timestamp,
                    "-t", image_latest,
                ] + build_args + ["."]
            }
        ],
        "images": [
            image_timestamp,
            image_latest
        ]
    }

    config_filename = "cloudbuild.json"

    try:
        with open(config_filename, "w") as f:
            json.dump(cloudbuild_config, f, indent=2)

        print(f"Generated {config_filename}")

        cmd = [
            "gcloud", "builds", "submit", source_path,
            "--config", config_filename,
            "--project", args.project_id,
            "--region", args.region
        ]

        print(f"Running: {' '.join(cmd)}")

        if args.no_submit:
            print("No-submit flag set; skipping build submission.")
            return

        subprocess.check_call(cmd)

    except subprocess.CalledProcessError as e:
        print(f"Error submitting build: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if not args.keep_config and os.path.exists(config_filename):
            os.remove(config_filename)
            print(f"Removed {config_filename}")
        # # Clean up copied email-relay directory
        # if email_relay_copied and os.path.isdir(email_relay_dst):
        #     shutil.rmtree(email_relay_dst)
        #     print(f"Cleaned up {email_relay_dst}")

if __name__ == "__main__":
    main()
