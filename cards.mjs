#!/usr/bin/env node
import { readFile, writeFile, mkdir } from "fs/promises";
import { existsSync } from "fs";

class GitHubStatsCollector {
  constructor(username, accessToken) {
    this.username = username;
    this.accessToken = accessToken;
    this.baseUrl = "https://api.github.com/graphql";
  }

  async graphQL(query) {
    try {
      const response = await fetch(this.baseUrl, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query }),
      });

      if (!response.ok) {
        throw new Error(`GraphQL request failed: ${response.status}`);
      }

      const result = await response.json();

      if (result.errors) {
        throw new Error(`GraphQL errors: ${JSON.stringify(result.errors)}`);
      }

      return result;
    } catch (error) {
      console.error("GraphQL query failed:", error.message);
      throw error;
    }
  }

  async getProfileData() {
    const query = `
        query {
            user(login: "${this.username}") {
                name
                login
                createdAt
                contributionsCollection {
                    totalCommitContributions
                    totalIssueContributions
                    totalPullRequestContributions
                    totalPullRequestReviewContributions
                    totalRepositoryContributions
                    restrictedContributionsCount
                    contributionYears
                }
                repositoriesContributedTo(first: 1, includeUserRepositories: true, privacy: PUBLIC, contributionTypes: [COMMIT, ISSUE, PULL_REQUEST, REPOSITORY]) {
                    totalCount
                }
                pullRequests(first: 1) {
                    totalCount
                }
                issues(first: 1) {
                    totalCount
                }
                followers {
                    totalCount
                }
                repositories(first: 100, orderBy: {field: STARGAZERS, direction: DESC}, isFork: false) {
                    totalCount
                    nodes {
                        id
                        name
                        stargazerCount
                        forkCount
                        primaryLanguage {
                            name
                            color
                        }
                        languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                            edges {
                                size
                                node {
                                    name
                                    color
                                }
                            }
                        }
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }`;

    const result = await this.graphQL(query);
    return result.data?.user;
  }

  async getMoreRepositories(cursor) {
    const query = `
        query {
            user(login: "${this.username}") {
                repositories(first: 100, after: "${cursor}", orderBy: {field: STARGAZERS, direction: DESC}, isFork: false) {
                    nodes {
                        id
                        name
                        stargazerCount
                        forkCount
                        primaryLanguage {
                            name
                            color
                        }
                        languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                            edges {
                                size
                                node {
                                    name
                                    color
                                }
                            }
                        }
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }`;

    const result = await this.graphQL(query);
    return result.data?.user?.repositories;
  }

  async getTotalContributions() {
    const query = `
        query {
            user(login: "${this.username}") {
                contributionsCollection {
                    contributionYears
                }
            }
        }`;

    try {
      const result = await this.graphQL(query);
      const years =
        result.data?.user?.contributionsCollection?.contributionYears || [];

      if (years.length === 0) return 0;

      const yearQueries = years
        .map(
          (year) => `
                year${year}: contributionsCollection(from: "${year}-01-01T00:00:00Z", to: "${
            year + 1
          }-01-01T00:00:00Z") {
                    totalCommitContributions
                    totalIssueContributions  
                    totalPullRequestContributions
                    totalPullRequestReviewContributions
                }
            `
        )
        .join("\n");

      const contributionsQuery = `
            query {
                user(login: "${this.username}") {
                    ${yearQueries}
                }
            }`;

      const contribResult = await this.graphQL(contributionsQuery);
      const userData = contribResult.data?.user || {};

      const totalContributions = Object.keys(userData)
        .filter((key) => key.startsWith("year"))
        .reduce((total, key) => {
          const yearData = userData[key];
          return (
            total +
            (yearData.totalCommitContributions || 0) +
            (yearData.totalIssueContributions || 0) +
            (yearData.totalPullRequestContributions || 0) +
            (yearData.totalPullRequestReviewContributions || 0)
          );
        }, 0);

      return totalContributions;
    } catch (error) {
      console.error("Failed to fetch contributions:", error.message);
      return 0;
    }
  }

  async getCommitLanguages(excludeLangs = new Set()) {
    const query = `
        query {
            user(login: "${this.username}") {
                contributionsCollection {
                    commitContributionsByRepository(maxRepositories: 100) {
                        repository {
                            primaryLanguage {
                                name
                                color
                            }
                        }
                        contributions {
                            totalCount
                        }
                    }
                }
            }
        }`;

    try {
      const result = await this.graphQL(query);
      const commitData =
        result.data?.user?.contributionsCollection
          ?.commitContributionsByRepository || [];

      const commitLanguages = {};

      commitData
        .filter((item) => {
          const primaryLang = item.repository?.primaryLanguage?.name;
          return (
            primaryLang &&
            !excludeLangs.has(primaryLang.toLowerCase()) &&
            (item.contributions?.totalCount || 0) > 0
          );
        })
        .forEach((item) => {
          const primaryLang = item.repository.primaryLanguage.name;
          const commitCount = item.contributions.totalCount;

          if (commitLanguages[primaryLang]) {
            commitLanguages[primaryLang].commits += commitCount;
          } else {
            commitLanguages[primaryLang] = {
              commits: commitCount,
              color: item.repository.primaryLanguage?.color || null,
            };
          }
        });

      const totalCommits = Object.values(commitLanguages).reduce(
        (sum, lang) => sum + lang.commits,
        0
      );
      if (totalCommits > 0) {
        Object.values(commitLanguages).forEach((lang) => {
          lang.prop = 100 * (lang.commits / totalCommits);
        });
      }

      return commitLanguages;
    } catch (error) {
      console.error("Failed to fetch commit languages:", error.message);
      return {};
    }
  }

  async getRepoLanguages(excludeLangs = new Set()) {
    try {
      let hasNextPage = true;
      let cursor = null;
      const repoLanguages = {};
      const nodes = [];

      while (hasNextPage) {
        const query = `
                query {
                    user(login: "${this.username}") {
                        repositories(isFork: false, first: 100${
                          cursor ? `, after: "${cursor}"` : ""
                        }, ownerAffiliations: OWNER) {
                            nodes {
                                primaryLanguage {
                                    name
                                    color
                                }
                            }
                            pageInfo {
                                endCursor
                                hasNextPage
                            }
                        }
                    }
                }`;

        const result = await this.graphQL(query);

        if (result.errors) {
          throw new Error(`GraphQL errors: ${JSON.stringify(result.errors)}`);
        }

        cursor = result.data?.user?.repositories?.pageInfo?.endCursor;
        hasNextPage = result.data?.user?.repositories?.pageInfo?.hasNextPage;
        nodes.push(...(result.data?.user?.repositories?.nodes || []));
      }

      nodes
        .filter((node) => {
          const primaryLang = node.primaryLanguage?.name;
          return primaryLang && !excludeLangs.has(primaryLang.toLowerCase());
        })
        .forEach((node) => {
          const primaryLang = node.primaryLanguage.name;

          if (repoLanguages[primaryLang]) {
            repoLanguages[primaryLang].count += 1;
          } else {
            repoLanguages[primaryLang] = {
              count: 1,
              color: node.primaryLanguage?.color || null,
            };
          }
        });

      const totalRepos = Object.values(repoLanguages).reduce(
        (sum, lang) => sum + lang.count,
        0
      );
      if (totalRepos > 0) {
        Object.values(repoLanguages).forEach((lang) => {
          lang.prop = 100 * (lang.count / totalRepos);
        });
      }

      return repoLanguages;
    } catch (error) {
      console.error("Failed to fetch repo languages:", error.message);
      return {};
    }
  }

  async getOrganizationRepositories(orgName) {
    const query = `
        query {
            organization(login: "${orgName}") {
                repositories(first: 100, orderBy: {field: STARGAZERS, direction: DESC}, isFork: false) {
                    nodes {
                        id
                        name
                        nameWithOwner
                        stargazerCount
                        forkCount
                        primaryLanguage {
                            name
                            color
                        }
                        languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                            edges {
                                size
                                node {
                                    name
                                    color
                                }
                            }
                        }
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }`;

    try {
      const result = await this.graphQL(query);
      return result.data?.organization?.repositories?.nodes || [];
    } catch (error) {
      console.error(
        `Failed to fetch org repositories for ${orgName}:`,
        error.message
      );
      return [];
    }
  }
}

const calculateRepoStats = (repositories, excludeRepos) => {
  const seenRepos = new Set();

  return repositories
    .filter((repo) => {
      if (excludeRepos.has(repo.name) || !repo.id || seenRepos.has(repo.id)) {
        if (seenRepos.has(repo.id)) {
          console.log(
            `Skipping duplicate repository: ${
              repo.nameWithOwner || repo.name
            } (ID: ${repo.id})`
          );
        }
        return false;
      }
      seenRepos.add(repo.id);
      return true;
    })
    .reduce(
      (stats, repo) => ({
        totalStars: stats.totalStars + (repo.stargazerCount || 0),
        totalForks: stats.totalForks + (repo.forkCount || 0),
      }),
      { totalStars: 0, totalForks: 0 }
    );
};

const parseEnvironment = () => {
  const accessToken = process.env.ACCESS_TOKEN;
  if (!accessToken) {
    throw new Error("ACCESS_TOKEN environment variable is required");
  }

  const username = process.env.GITHUB_ACTOR;
  if (!username) {
    throw new Error("GITHUB_ACTOR environment variable is required");
  }

  const {
    EXCLUDED_REPOS: excludedRepos,
    EXCLUDED_LANGS: excludedLangs,
    INCLUDE_ORGS: includeOrgs,
  } = process.env;

  const excludeRepos = excludedRepos
    ? new Set(
        excludedRepos
          .split(",")
          .map((repo) => repo.trim())
          .filter(Boolean)
      )
    : new Set();

  const excludeLangs = excludedLangs
    ? new Set(
        excludedLangs
          .split(",")
          .map((lang) => lang.trim().toLowerCase())
          .filter(Boolean)
      )
    : new Set();

  if (excludedLangs) {
    console.log(`Excluding languages: ${Array.from(excludeLangs).join(", ")}`);
  }

  const includeOrgsList = includeOrgs
    ? includeOrgs
        .split(",")
        .map((org) => org.trim())
        .filter(Boolean)
    : [];

  return { accessToken, username, excludeRepos, excludeLangs, includeOrgsList };
};

const generateOverview = async (data) => {
  try {
    const template = await readFile("templates/overview.svg", "utf8");

    let output = template
      .replace(/{{ name }}/g, data.name || "Unknown")
      .replace(/{{ stars }}/g, data.totalStars.toLocaleString())
      .replace(/{{ forks }}/g, data.totalForks.toLocaleString())
      .replace(/{{ contributions }}/g, data.totalContributions.toLocaleString())
      .replace(/{{ commits }}/g, data.totalCommits.toLocaleString())
      .replace(/{{ yearsAgo }}/g, data.yearsAgo || 0)
      .replace(/{{ repos }}/g, data.repoCount.toLocaleString());

    if (!existsSync("output")) await mkdir("output", { recursive: true });
    await writeFile("output/overview.svg", output);

    console.log("Generated overview.svg");
  } catch (error) {
    console.error("Failed to generate overview:", error.message);
    throw error;
  }
};

const generateLanguages = async (
  languages,
  filename = "languages.svg",
  sortKey = "size"
) => {
  try {
    const template = await readFile("templates/languages.svg", "utf8");

    const sortedLanguages = Object.entries(languages).sort(
      ([, a], [, b]) => (b[sortKey] || 0) - (a[sortKey] || 0)
    );

    let progress = "";
    let langList = "";
    const delayBetween = 150;

    const total = sortedLanguages.reduce(
      (sum, [, data]) => sum + (data[sortKey] || 0),
      0
    );

    sortedLanguages.forEach(([langName, data], i) => {
      const color = data.color || "#000000";
      const value = data[sortKey] || 0;
      const proportion = total > 0 ? (value / total) * 100 : 0;

      let ratio = [0.98, 0.02];
      if (proportion > 50) {
        ratio = [0.99, 0.01];
      }
      if (i === sortedLanguages.length - 1) {
        ratio = [1, 0];
      }

      const width = (ratio[0] * proportion).toFixed(3);
      const marginRight = (ratio[1] * proportion).toFixed(3);

      progress += `<span style="background-color: ${color};width: ${width}%;margin-right: ${marginRight}%;" class="progress-item"></span>`;

      const metricValue = `${proportion.toFixed(2)}%`;

      langList += `
<li style="animation-delay: ${i * delayBetween}ms;">
<svg xmlns="http://www.w3.org/2000/svg" class="octicon" style="fill:${color};"
viewBox="0 0 16 16" version="1.1" width="16" height="16"><path
fill-rule="evenodd" d="M8 4a4 4 0 100 8 4 4 0 000-8z"></path></svg>
<span class="lang">${langName}</span>
<span class="percent">${metricValue}</span>
</li>

`;
    });

    const title =
      sortKey === "commits"
        ? "Top Languages by Commits"
        : "Top Languages by Repo";

    const output = template
      .replace(/{{ progress }}/g, progress)
      .replace(/{{ lang_list }}/g, langList)
      .replace(/Most Used Languages/g, title);

    if (!existsSync("output")) await mkdir("output", { recursive: true });
    await writeFile(`output/${filename}`, output);

    console.log(`Generated ${filename}`);
  } catch (error) {
    console.error(`Failed to generate ${filename}:`, error.message);
    throw error;
  }
};

const generateStatsSummary = async (data, profileData) => {
  try {
    const years = data.yearsAgo;
    const commits = data.totalCommits.toLocaleString();
    const issues = (profileData.issues?.totalCount || 0).toLocaleString();
    const stars = data.totalStars.toLocaleString();
    const repos = (profileData.repositories?.totalCount || 0).toLocaleString();
    const contributedRepos = (profileData.repositoriesContributedTo?.totalCount || 0).toLocaleString();

    const summary = `I'm Papuna, an open-source developer and DevOps engineer. I joined GitHub **${years} ${years === 1 ? 'year' : 'years'}** ago and since then I have pushed **${commits} commits**, opened **${issues} issues**, and received **${stars} stars** across my projects.`;

    if (!existsSync("output")) await mkdir("output", { recursive: true });
    await writeFile("output/stats-summary.txt", summary);

    console.log("Generated stats summary");
    console.log(summary);
  } catch (error) {
    console.error("Failed to generate stats summary:", error.message);
    throw error;
  }
};

const updateReadmeWithStats = async () => {
  try {
    const readmePath = "README.md";
    const statsSummaryPath = "output/stats-summary.txt";

    if (!existsSync(statsSummaryPath)) {
      console.log("Stats summary file not found, skipping README update");
      return;
    }

    const readme = await readFile(readmePath, "utf8");
    const statsSummary = await readFile(statsSummaryPath, "utf8");

    const startMarker = "<!--START_SECTION:stats-summary-->";
    const endMarker = "<!--END_SECTION:stats-summary-->";

    const startIndex = readme.indexOf(startMarker);
    const endIndex = readme.indexOf(endMarker);

    if (startIndex === -1 || endIndex === -1) {
      console.log("README markers not found, skipping update");
      return;
    }

    const before = readme.substring(0, startIndex + startMarker.length);
    const after = readme.substring(endIndex);
    const updatedReadme = `${before}\n${statsSummary}\n${after}`;

    await writeFile(readmePath, updatedReadme);
    console.log("Updated README with stats summary");
  } catch (error) {
    console.error("Failed to update README:", error.message);
    throw error;
  }
};

const fetchAllContributions = async (collector, contributionsData) => {
  const contributionYears = contributionsData.contributionYears || [];
  console.log("Fetching total contributions across all years...");

  let total = 0;
  const yearPromises = contributionYears.slice(0, 7).map(async (year) => {
    console.log(`Fetching all contributions for ${year}...`);
    const yearResult = await collector.graphQL(`
        query {
            user(login: "${collector.username}") {
                contributionsCollection(from: "${year}-01-01T00:00:00Z", to: "${year}-12-31T23:59:59Z") {
                    contributionCalendar {
                        totalContributions
                    }
                }
            }
        }`);
    const yearTotal =
      yearResult.data?.user?.contributionsCollection?.contributionCalendar
        ?.totalContributions || 0;
    console.log(`${year}: ${yearTotal} total contributions`);
    return yearTotal;
  });

  const yearTotals = await Promise.all(yearPromises);
  total = yearTotals.reduce((sum, yearTotal) => sum + yearTotal, 0);
  return total;
};

const fetchAllCommits = async (collector, contributionsData) => {
  const contributionYears = contributionsData.contributionYears || [];
  console.log(`Found contribution years: ${contributionYears.join(", ")}`);

  let total = 0;
  const commitPromises = contributionYears.slice(0, 5).map(async (year) => {
    console.log(`Fetching commits for ${year}...`);
    const yearResult = await collector.graphQL(`
        query {
            user(login: "${collector.username}") {
                contributionsCollection(from: "${year}-01-01T00:00:00Z", to: "${year}-12-31T23:59:59Z") {
                    totalCommitContributions
                }
            }
        }`);
    const yearCommits =
      yearResult.data?.user?.contributionsCollection
        ?.totalCommitContributions || 0;
    console.log(`${year}: ${yearCommits} commits`);
    return yearCommits;
  });

  const commitTotals = await Promise.all(commitPromises);
  total = commitTotals.reduce((sum, yearCommits) => sum + yearCommits, 0);
  console.log(
    `Total commits across ${
      contributionYears.slice(0, 5).length
    } years: ${total}`
  );
  return total;
};

const main = async () => {
  try {
    console.log("Starting improved GitHub stats generation...");

    const config = parseEnvironment();
    const collector = new GitHubStatsCollector(
      config.username,
      config.accessToken
    );

    console.log(`Generating stats for: ${config.username}`);

    const profileData = await collector.getProfileData();

    if (!profileData) {
      throw new Error("Failed to fetch user profile data");
    }

    let allRepositories = profileData.repositories.nodes || [];
    let { hasNextPage, endCursor: cursor } =
      profileData.repositories.pageInfo || {};

    while (hasNextPage && cursor) {
      console.log(`Fetching additional repositories...`);
      const moreRepos = await collector.getMoreRepositories(cursor);

      allRepositories = allRepositories.concat(moreRepos.nodes || []);
      ({ hasNextPage, endCursor: cursor } = moreRepos.pageInfo || {});
    }

    if (config.includeOrgsList.length > 0) {
      console.log(
        `Fetching repositories from organizations: ${config.includeOrgsList.join(
          ", "
        )}`
      );

      const orgRepoPromises = config.includeOrgsList.map(async (orgName) => {
        const orgRepos = await collector.getOrganizationRepositories(orgName);
        console.log(`Found ${orgRepos.length} repositories in ${orgName}`);
        return orgRepos;
      });

      const orgRepoResults = await Promise.all(orgRepoPromises);
      allRepositories = allRepositories.concat(...orgRepoResults);
    }

    const { totalStars, totalForks } = calculateRepoStats(
      allRepositories,
      config.excludeRepos
    );

    const totalContributions = await fetchAllContributions(
      collector,
      profileData.contributionsCollection
    );

    console.log(
      "Fetching repository languages (matching reference implementation)..."
    );
    const repoLanguages = await collector.getRepoLanguages(config.excludeLangs);

    console.log(
      "Fetching commit languages (matching reference implementation)..."
    );
    const commitLanguages = await collector.getCommitLanguages(
      config.excludeLangs
    );

    const totalCommits = await fetchAllCommits(
      collector,
      profileData.contributionsCollection
    );

    const joinedDate = new Date(profileData.createdAt);
    const currentDate = new Date();
    const yearsAgo = Math.floor(
      (currentDate.getTime() - joinedDate.getTime()) /
        (1000 * 60 * 60 * 24 * 365.25)
    );

    const statsData = {
      name: profileData.name || profileData.login,
      totalStars,
      totalForks,
      totalContributions,
      totalCommits,
      yearsAgo,
      repoCount:
        profileData.repositoriesContributedTo?.totalCount ||
        allRepositories.length,
    };

    await Promise.all([
      generateOverview(statsData),
      generateLanguages(repoLanguages, "languages-repo.svg", "count"),
      generateLanguages(commitLanguages, "languages-commit.svg", "commits"),
      generateStatsSummary(statsData, profileData),
    ]);

    await updateReadmeWithStats();

    console.log("Successfully generated improved statistics images");
  } catch (error) {
    console.error("Failed to generate statistics:", error.message);
    process.exit(1);
  }
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
