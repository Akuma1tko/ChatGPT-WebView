#!/usr/bin/env bash
set -euo pipefail

cat <<'BANNER'
ChatGPT WebView BYO Supabase Memory Setup
=========================================

This script links a Supabase project, pushes the memory schema migration,
and deploys the memory Edge Function.

It never asks for, stores, or prints a service role key.
BANNER

if ! command -v supabase >/dev/null 2>&1; then
  echo "ERROR: Supabase CLI is not installed."
  echo "Install it first: https://supabase.com/docs/guides/cli"
  exit 1
fi

PROJECT_REF="${1:-}"
if [[ -z "${PROJECT_REF}" ]]; then
  read -r -p "Supabase project ref, for example abcdefghijklmnop: " PROJECT_REF
fi

if [[ -z "${PROJECT_REF}" ]]; then
  echo "ERROR: project ref is required."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo
echo "Linking Supabase project ${PROJECT_REF}..."
supabase link --project-ref "${PROJECT_REF}"

echo
echo "Pushing database migrations..."
supabase db push

echo
echo "Deploying memory Edge Function..."
supabase functions deploy memory

echo
echo "Setup commands completed."
echo
echo "Next steps:"
echo "1. In Supabase, open Project Settings -> API Keys and copy the publishable key."
echo "2. In the iOS app, enter:"
echo "   Project URL: https://${PROJECT_REF}.supabase.co"
echo "   Publishable key: <your publishable key>"
echo "3. Run diagnostics in the app."
echo "4. Optional social login: enable providers in Supabase Auth Providers."
echo
echo "Callback URL for social providers:"
echo "https://${PROJECT_REF}.supabase.co/auth/v1/callback"
echo
echo "Callback URL to add in Supabase Auth URL Configuration:"
echo "chatgptwebview://auth-callback"
