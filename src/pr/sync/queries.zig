//! GraphQL texts for the PR sync engine. Each operation is named so the fake
//! `gh` used by the harness, and anyone reading `gh` logs, can tell them apart.
//! Byte-identical copies live in scripts/test-infra/pr-sidebar/sync/*.graphql; a
//! test in pr_sync_test_root.zig fails when they drift.

pub const index_page_size = 100;
pub const closed_page_size = 50;
pub const reconcile_page_size = 100;
pub const hydrate_batch_size = 25;

pub const index_query =
    \\query SkimSyncIndex($owner: String!, $name: String!, $cursor: String) {
    \\  viewer {
    \\    login
    \\  }
    \\  repository(owner: $owner, name: $name) {
    \\    pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
    \\      pageInfo {
    \\        hasNextPage
    \\        endCursor
    \\      }
    \\      nodes {
    \\        id
    \\        number
    \\        title
    \\        isDraft
    \\        updatedAt
    \\        url
    \\        headRefName
    \\        baseRefName
    \\        headRefOid
    \\        baseRefOid
    \\        author {
    \\          login
    \\        }
    \\        labels(first: 20) {
    \\          nodes {
    \\            name
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

pub const closed_query =
    \\query SkimSyncClosed($owner: String!, $name: String!, $cursor: String) {
    \\  repository(owner: $owner, name: $name) {
    \\    pullRequests(states: [CLOSED, MERGED], first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
    \\      pageInfo {
    \\        hasNextPage
    \\        endCursor
    \\      }
    \\      nodes {
    \\        number
    \\        state
    \\        updatedAt
    \\      }
    \\    }
    \\  }
    \\}
;

pub const reconcile_query =
    \\query SkimSyncReconcile($owner: String!, $name: String!, $cursor: String) {
    \\  repository(owner: $owner, name: $name) {
    \\    pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
    \\      pageInfo {
    \\        hasNextPage
    \\        endCursor
    \\      }
    \\      nodes {
    \\        number
    \\      }
    \\    }
    \\  }
    \\}
;

pub const hydrate_query =
    \\query SkimSyncHydrate($ids: [ID!]!) {
    \\  nodes(ids: $ids) {
    \\    ... on PullRequest {
    \\      number
    \\      updatedAt
    \\      additions
    \\      deletions
    \\      changedFiles
    \\      reviewDecision
    \\      reviewRequests(first: 20) {
    \\        nodes {
    \\          requestedReviewer {
    \\            __typename
    \\            ... on User {
    \\              login
    \\            }
    \\            ... on Team {
    \\              slug
    \\              organization {
    \\                login
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\      latestOpinionatedReviews(first: 50) {
    \\        nodes {
    \\          author {
    \\            login
    \\          }
    \\          state
    \\          commit {
    \\            oid
    \\          }
    \\        }
    \\      }
    \\      commits(last: 1) {
    \\        nodes {
    \\          commit {
    \\            statusCheckRollup {
    \\              state
    \\            }
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

pub const teams_query =
    \\query SkimSyncTeams($owner: String!, $login: String!) {
    \\  viewer {
    \\    organization(login: $owner) {
    \\      teams(first: 100, userLogins: [$login]) {
    \\        nodes {
    \\          slug
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;
