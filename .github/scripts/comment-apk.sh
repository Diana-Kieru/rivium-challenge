#!/usr/bin/env bash
# Post or update a pull request comment with the debug APK artifact link.
# Runs from comment-apk.yml after Build APK finishes. Fork pull requests
# cannot comment during the build job, so this runs in the base repository.
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${WORKFLOW_EVENT:?}"
: "${WORKFLOW_CONCLUSION:?}"
: "${WORKFLOW_RUN_ID:?}"
: "${HEAD_REPO:?}"
: "${HEAD_BRANCH:?}"

if [[ "$WORKFLOW_EVENT" != "pull_request" ]]; then
  echo "Event is $WORKFLOW_EVENT. No pull request to comment on."
  exit 0
fi

if [[ "$WORKFLOW_CONCLUSION" != "success" && "$WORKFLOW_CONCLUSION" != "failure" ]]; then
  echo "Conclusion is $WORKFLOW_CONCLUSION. Not commenting."
  exit 0
fi

owner="${HEAD_REPO%%/*}"
pr_number=$(
  gh api "repos/${GITHUB_REPOSITORY}/pulls?head=${owner}:${HEAD_BRANCH}&state=open" \
    --jq '.[0].number // empty'
)
if [[ -z "$pr_number" ]]; then
  echo "No open pull request for ${owner}:${HEAD_BRANCH}."
  exit 0
fi

run_url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${WORKFLOW_RUN_ID}"
artifact_id=$(
  gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${WORKFLOW_RUN_ID}/artifacts" \
    --jq ".artifacts[] | select(.name==\"apk-pr-${pr_number}\") | .id" \
    | head -n 1
)
marker="<!-- apk-artifact -->"

if [[ -n "$artifact_id" ]]; then
  artifact_url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${WORKFLOW_RUN_ID}/artifacts/${artifact_id}"
  body=$(cat <<EOF
${marker}
Debug APK is ready: ${artifact_url}

The download is a zip of the debug APKs from [run ${WORKFLOW_RUN_ID}](${run_url}). It is kept for 14 days.
EOF
)
  if [[ "$WORKFLOW_CONCLUSION" != "success" ]]; then
    body="${body}

The workflow run did not fully succeed, so some projects in that zip may be missing."
  fi
elif [[ "$WORKFLOW_CONCLUSION" == "failure" ]]; then
  body=$(cat <<EOF
${marker}
The APK build failed. Log: ${run_url}
EOF
)
else
  echo "No APK artifact for pull request #${pr_number}. Not commenting."
  exit 0
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "Would comment on #${pr_number}:"
  printf '%s\n' "$body"
  exit 0
fi

existing=$(
  gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" \
    --jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
    | head -n 1
)
if [[ -n "$existing" ]]; then
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${existing}" -f body="$body" >/dev/null
  echo "Updated comment ${existing} on #${pr_number}."
else
  gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" -f body="$body" >/dev/null
  echo "Commented on #${pr_number}."
fi
