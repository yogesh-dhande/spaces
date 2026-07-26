#!/usr/bin/env bash

spaces_e2e_install_demo_fixture() {
  local template_dir="$1"
  local variant="$2"
  local repo_dir="$3"
  local readme_title="$4"

  (
    cd "$repo_dir"
    git init -q -b main
    git config user.email "spaces-e2e@example.com"
    git config user.name "spaces-e2e"
    mkdir -p .spaces-e2e-demo
    cp "$template_dir/pyproject.toml" .spaces-e2e-demo/pyproject.toml
    cp -R "$template_dir/src" .spaces-e2e-demo/src
    cp -R "$template_dir/templates/$variant/site" .spaces-e2e-demo/site
    cp -R "$template_dir/templates/$variant/api" .spaces-e2e-demo/api
    printf '%s\n' "$readme_title" >README.md
    git add README.md .spaces-e2e-demo
    git commit -q -m init
  )
}

spaces_e2e_install_demo_fixture_branch() {
  local template_dir="$1"
  local variant="$2"
  local repo_dir="$3"
  local branch_name="$4"

  (
    cd "$repo_dir"
    git checkout -q -b "$branch_name"
    rm -rf .spaces-e2e-demo/site
    rm -rf .spaces-e2e-demo/api
    cp -R "$template_dir/templates/$variant/site" .spaces-e2e-demo/site
    cp -R "$template_dir/templates/$variant/api" .spaces-e2e-demo/api
    git add .spaces-e2e-demo/site .spaces-e2e-demo/api
    git commit -q -m "redesign hero section"
    git checkout -q main
  )
}

spaces_e2e_create_harbor_fixture_repo() {
  local template_dir="$1"
  local repo_dir="$2"

  mkdir -p "$repo_dir"
  spaces_e2e_install_demo_fixture "$template_dir" "harbor" "$repo_dir" "# Harbor Web"
  spaces_e2e_install_demo_fixture_branch "$template_dir" "harbor-redesign-hero" "$repo_dir" "redesign-hero"
}

spaces_e2e_create_lantern_fixture_repo() {
  local template_dir="$1"
  local repo_dir="$2"

  mkdir -p "$repo_dir"
  spaces_e2e_install_demo_fixture "$template_dir" "lantern" "$repo_dir" "# Lantern API"
  spaces_e2e_install_demo_fixture_branch "$template_dir" "lantern-redesign-hero" "$repo_dir" "redesign-hero"
}

spaces_e2e_create_atlas_fixture_repo() {
  local template_dir="$1"
  local repo_dir="$2"

  mkdir -p "$repo_dir"
  spaces_e2e_install_demo_fixture "$template_dir" "atlas" "$repo_dir" "# Atlas Docs"
}

spaces_e2e_create_standard_fixture_repos() {
  local template_dir="$1"
  local harbor_repo="$2"
  local lantern_repo="$3"
  local atlas_repo="$4"

  spaces_e2e_create_harbor_fixture_repo "$template_dir" "$harbor_repo"
  spaces_e2e_create_lantern_fixture_repo "$template_dir" "$lantern_repo"
  spaces_e2e_create_atlas_fixture_repo "$template_dir" "$atlas_repo"
}
