OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d '/' -f1)
REPO=$(echo "$GITHUB_REPOSITORY" | cut -d '/' -f2)

# function: get_issue_node_id, param: issue_number
get_issue_node_id() {
  local issue_number="$1"
  local response
  response=$(gh api graphql -f query='
   query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       issue(number: $number) { id }
     }
   }' \
   -F owner="$OWNER" -F repo="$REPO" -F number="$issue_number")
  echo "API response: $response"
  echo "$response" | jq -r '.data.repository.issue.id'
}

# function: print_issue_status, param: issue_node_id
print_issue_status() {
  local issue_node_id="$1"
  echo "Received issue node ID in print_issue_status: $issue_node_id"
  gh api graphql -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on Issue {
          projectItems(first: 20) {
            nodes {
              project { title }
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    field { ... on ProjectV2FieldCommon { name } }
                    name
                  }
                  ... on ProjectV2ItemFieldTextValue {
                    field { ... on ProjectV2FieldCommon { name } }
                    text
                  }}}}}}}}
  ' --field id="$issue_node_id" \
  | jq -r '
      .data.node.projectItems.nodes[] |
      select(.project != null) |
      {project: .project.title, status: (.fieldValues.nodes[]? | select(.field.name=="Status") | (.name // .text // "No Status"))} |
      "  - \(.project): \(.status)"
    '
  echo "Exiting print_issue_status for issue node ID: $issue_node_id"
}

# function: update_issue_status, params: issue_node_id, issue_number, target_status
update_issue_status() {
  local issue_node_id="$1"
  local issue_number="$2"
  local target_status="$3"
  
  echo "=========================================="
  echo "Updating issue #$issue_number to status: $target_status"
  echo "Issue Node ID: $issue_node_id"
  echo "=========================================="
  
  # Debug: Check token and environment
  echo "Verifying GitHub API access..."
  echo "GITHUB_TOKEN set: ${GITHUB_TOKEN:+YES (${#GITHUB_TOKEN} chars)}"
  echo "GH_TOKEN set: ${GH_TOKEN:+YES}"
  
  # Test API access
  local auth_test
  auth_test=$(gh api user 2>&1)
  if [ $? -ne 0 ]; then
    echo "Error: GitHub token authentication failed"
    echo "Auth test output: $auth_test"
    echo ""
    echo "Troubleshooting:"
    echo "1. Ensure GITHUB_TOKEN is set in workflow env"
    echo "2. Check GitHub App has required permissions:"
    echo "   - Contents: read"
    echo "   - Issues: read"
    echo "   - Projects: write (organization_projects or repository_projects)"
    echo "3. Verify token is passed to action correctly"
    return 1
  fi
  echo "✓ Token is valid (user: $(echo "$auth_test" | jq -r '.login'))"
  
  # Get project items for the issue
  echo ""
  echo "Fetching project items for issue..."
  local project_items
  project_items=$(gh api graphql --field id="$issue_node_id" -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on Issue {
          projectItems(first: 20) {
            nodes {
              id
              project {
                id
                title
              }
            }
          }
        }
      }
    }')
  
  # Debug: Show raw response
  echo "Raw GraphQL response:"
  echo "$project_items" | jq '.'
  
  # Check for GraphQL errors
  if echo "$project_items" | jq -e '.errors' >/dev/null 2>&1; then
    echo "GraphQL Error occurred:"
    echo "$project_items" | jq -r '.errors[] | "  - \(.message)"'
    return 1
  fi
  
  local item_count
  item_count=$(echo "$project_items" | jq -r '.data.node.projectItems.nodes | length')
  
  echo "Found $item_count project item(s)"
  
  if [ "$item_count" = "0" ] || [ "$item_count" = "null" ]; then
    echo "Issue #$issue_number is not linked to any GitHub Projects"
    return 0
  fi
  
  local updated=0 failed=0
  
  while read -r item; do
    local project_item_id project_id project_title
    project_item_id=$(echo "$item" | jq -r '.id')
    project_id=$(echo "$item" | jq -r '.project.id')
    project_title=$(echo "$item" | jq -r '.project.title')
    
    echo ""
    echo "----------------------------------------"
    echo "Processing project: $project_title"
    echo "  Project ID: $project_id"
    echo "  Item ID: $project_item_id"
    
    # Get Status field and options
    echo "  Fetching Status field configuration..."
    local status_info
    status_info=$(gh api graphql --field projectId="$project_id" -f query='
      query($projectId: ID!) {
        node(id: $projectId) {
          ... on ProjectV2 {
            field(name: "Status") {
              ... on ProjectV2SingleSelectField {
                id
                options {
                  id
                  name
                }
              }
            }
          }
        }
      }')
    
    # Debug: Show status field info
    echo "  Status field response:"
    echo "$status_info" | jq '.'
    
    local status_field_id
    status_field_id=$(echo "$status_info" | jq -r '.data.node.field.id // empty')
    
    if [ -z "$status_field_id" ] || [ "$status_field_id" = "null" ]; then
      echo "  ✗ Warning: No 'Status' field found in project '$project_title'"
      echo "  Available fields in project:"
      gh api graphql --field projectId="$project_id" -f query='
        query($projectId: ID!) {
          node(id: $projectId) {
            ... on ProjectV2 {
              fields(first: 10) {
                nodes {
                  ... on ProjectV2FieldCommon {
                    name
                  }
                }
              }
            }
          }
        }' | jq -r '.data.node.fields.nodes[] | "    - \(.name)"'
      failed=$((failed + 1))
      continue
    fi
    
    echo "  Status Field ID: $status_field_id"
    
    # Find the option ID for target status
    local option_id
    option_id=$(echo "$status_info" | jq -r --arg s "$target_status" \
      '.data.node.field.options[] | select(.name==$s) | .id')
    
    if [ -z "$option_id" ] || [ "$option_id" = "null" ]; then
      echo "  ✗ Error: Status '$target_status' not found in project '$project_title'"
      echo "  Available statuses:"
      echo "$status_info" | jq -r '.data.node.field.options[] | "    - \(.name)"'
      failed=$((failed + 1))
      continue
    fi
    
    echo "  Target Status: $target_status"
    echo "  Option ID: $option_id"
    
    # Update the project item status
    echo "  Executing mutation..."
    local result
    result=$(gh api graphql \
      --field projectId="$project_id" \
      --field itemId="$project_item_id" \
      --field fieldId="$status_field_id" \
      --field optionId="$option_id" \
      -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { singleSelectOptionId: $optionId }
        }) {
          projectV2Item {
            id
          }
        }
      }')
    
    # Debug: Show mutation response
    echo "  Mutation response:"
    echo "$result" | jq '.'
    
    # Check if update was successful
    if echo "$result" | jq -e '.data.updateProjectV2ItemFieldValue.projectV2Item.id' >/dev/null 2>&1; then
      echo "  ✓ Successfully updated issue #$issue_number in '$project_title'"
      updated=$((updated + 1))
    else
      echo "  ✗ Failed to update issue #$issue_number in '$project_title'"
      if echo "$result" | jq -e '.errors' >/dev/null 2>&1; then
        echo "  Errors:"
        echo "$result" | jq -r '.errors[] | "    - \(.message)"'
      fi
      failed=$((failed + 1))
    fi
    
  done < <(echo "$project_items" | jq -c '.data.node.projectItems.nodes[]')
  
  echo ""
  echo "=========================================="
  echo "Summary: Updated $updated project(s), Failed $failed project(s)"
  echo "=========================================="
  [ "$failed" -gt 0 ] && return 1 || return 0
}