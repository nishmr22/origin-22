source ".github/bash_scripts/issue_utils.sh"
if [ -z "$GH_TOKEN" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
  echo "Using GITHUB_TOKEN for GH_TOKEN"
fi
echo "Getting all open PRs from repository: $GITHUB_REPOSITORY"
readarray -t PRS < <(gh api repos/$GITHUB_REPOSITORY/pulls --paginate --jq '.[] | select(.state=="open") | .number')

if (( ${#PRS[@]} == 0 )); then
    echo "No open PRs found"
    exit 0
fi

echo "Found ${#PRS[@]} open PR(s)"

for PR_NUMBER in "${PRS[@]}"; do

    echo "Fetching linked issues of PR #$PR_NUMBER"
    readarray -t linked_issues < <(
        gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \
        --json closingIssuesReferences \
        --jq '.closingIssuesReferences[]?.number'
    )

    if (( ${#linked_issues[@]} == 0 )); then
        echo "No linked issues found for PR #$PR_NUMBER"
        continue
    fi

    echo "Found ${#linked_issues[@]} linked issue(s): ${linked_issues[*]}"

    for linked_issue_number in "${linked_issues[@]}"; do
      echo "Updating issue #$linked_issue_number to status: In Review"
      ISSUE_NODE_ID=$(get_issue_node_id "$linked_issue_number")
      if [ -z "$ISSUE_NODE_ID" ] || [ "$ISSUE_NODE_ID" = "null" ]; then
        echo "Error: Issue #$linked_issue_number not found in repository $GITHUB_REPOSITORY"
        continue
      fi
      echo "Issue Node ID: $ISSUE_NODE_ID"
      echo "Current status:"
      print_issue_status "$ISSUE_NODE_ID"
      update_issue_status "$ISSUE_NODE_ID" "$linked_issue_number" "In Review"
      echo ""
    done
    echo ""

done

