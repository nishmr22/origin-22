OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d '/' -f1)
REPO=$(echo "$GITHUB_REPOSITORY" | cut -d '/' -f2)

# function: get_issue_node_id, param: issue_number
get_issue_node_id() {
  local issue_number="$1"
  gh api graphql -f query='
   query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       issue(number: $number) { id }
     }
   }' \
   -F owner="$OWNER" -F repo="$REPO" -F number="$issue_number" \
   | jq -r '.data.repository.issue.id'
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
# Improved update_issue_status function
update_issue_status() {
  echo "token scope"
  echo $GITHUB_TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.'

  local issue_node_id="$1"
  local issue_number="$2"
  local target_status="$3"
  
  echo "Updating issue #$issue_number to status: $target_status"
  
  # Get project items for the issue
  local project_items
  project_items=$(gh api graphql -f query='
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
    }' --field id="$issue_node_id")
  
  local item_count
  item_count=$(echo "$project_items" | jq '.data.node.projectItems.nodes | length')
  
  if [ "$item_count" = "0" ]; then
    echo "Issue #$issue_number is not linked to any GitHub Projects"
    return 0
  fi
  
  local updated=0 failed=0
  
  while read -r item; do
    local project_item_id project_id project_title
    project_item_id=$(echo "$item" | jq -r '.id')
    project_id=$(echo "$item" | jq -r '.project.id')
    project_title=$(echo "$item" | jq -r '.project.title')
    
    echo "Processing project: $project_title"
    
    # Get Status field and options
    local status_info
    status_info=$(gh api graphql -f query='
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
      }' -F projectId="$project_id")
    
    local status_field_id
    status_field_id=$(echo "$status_info" | jq -r '.data.node.field.id')
    
    if [ "$status_field_id" = "null" ] || [ -z "$status_field_id" ]; then
      echo "Warning: No 'Status' field found in project '$project_title'"
      failed=$((failed + 1))
      continue
    fi
    
    # Find the option ID for target status
    local option_id
    option_id=$(echo "$status_info" | jq -r --arg s "$target_status" \
      '.data.node.field.options[] | select(.name==$s) | .id')
    
    if [[ -z "$option_id" || "$option_id" == "null" ]]; then
      echo "Error: Status '$target_status' not found in project '$project_title'"
      echo "Available statuses:"
      echo "$status_info" | jq -r '.data.node.field.options[] | "  - " + .name'
      failed=$((failed + 1))
      continue
    fi
    
    echo "Updating to status: $target_status (option_id: $option_id)"
    
    # Update the project item status
    local result
    result=$(gh api graphql -f query='
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
      }
    ' -F projectId="$project_id" \
      -F itemId="$project_item_id" \
      -F fieldId="$status_field_id" \
      -F optionId="$option_id")
    
    # Check if update was successful
    if echo "$result" | jq -e '.data.updateProjectV2ItemFieldValue.projectV2Item.id' >/dev/null 2>&1; then
      echo "✓ Successfully updated issue #$issue_number in '$project_title'"
      updated=$((updated + 1))
    else
      echo "✗ Failed to update issue #$issue_number in '$project_title'"
      echo "Response: $(echo "$result" | jq -c '.')"
      failed=$((failed + 1))
    fi
    
  done < <(echo "$project_items" | jq -c '.data.node.projectItems.nodes[]')
  
  echo ""
  echo "Summary: Updated $updated project(s), Failed $failed project(s)"
  [ "$failed" -gt 0 ] && return 1 || return 0
}

