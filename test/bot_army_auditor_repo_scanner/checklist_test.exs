defmodule BotArmyAuditorRepoScanner.ChecklistTest do
  @moduledoc """
  L1 tests for the bot-contract checklist engine.

  Fixture repos are built in tmp dirs (with a real `git init` so the git-based
  checks exercise the same code paths as production scans).
  """

  use ExUnit.Case, async: true

  alias BotArmyAuditorRepoScanner.Checklist

  @moduletag :tmp_dir

  setup do
    root = System.tmp_dir!() |> Path.join("repo_scanner_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # ── Fixture builders ─────────────────────────────────────────────────────

  defp build_full_bot(root, name \\ "bot_army_full") do
    repo = Path.join(root, name)
    File.mkdir_p!(Path.join(repo, "config"))
    File.mkdir_p!(Path.join(repo, "lib/bot"))
    File.mkdir_p!(Path.join(repo, "test"))

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule BotFull.MixProject do
      use Mix.Project

      def project do
        [
          app: :bot_full,
          version: "1.2.3",
          deps: [],
          releases: [bot_full_bot: [applications: [bot_full: :permanent]]]
        ]
      end
    end
    """)

    File.write!(Path.join(repo, "mix.lock"), "%{}")
    File.write!(Path.join(repo, "config/prod.exs"), "import Config\n")
    File.write!(Path.join(repo, "config/runtime.exs"), "import Config\n")
    File.write!(Path.join(repo, "README.md"), "# bot\n")
    File.write!(Path.join(repo, "Makefile"), "test:\n\tpub\npublish-release:\n\tpub\n")

    File.write!(Path.join(repo, "lib/bot/consumer.ex"), """
    defmodule BotFull.Consumer do
      @env Mix.env()
      def env, do: @env
    end
    """)

    File.write!(Path.join(repo, "test/consumer_test.exs"), "defmodule ConsumerTest do\nend\n")

    # Wire hooks BEFORE the commit so the tree stays clean → healthy verdict.
    File.mkdir_p!(Path.join(repo, "git-hooks"))
    File.write!(Path.join(repo, "git-hooks/pre-push"), "#!/bin/bash\n")
    git_init(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "config", "core.hooksPath", "git-hooks"])
    repo
  end

  defp build_broken_bot(root, name \\ "bot_army_broken") do
    repo = Path.join(root, name)
    File.mkdir_p!(repo)
    File.mkdir_p!(Path.join(repo, "config"))
    # Unconditional per-env import: the one shape that makes prod.exs a
    # hard requirement, so the required-fail below is honest.
    File.write!(Path.join(repo, "config/config.exs"), "import Config\n\nimport_config \"\#{Mix.env()}.exs\"\n")
    File.write!(Path.join(repo, "mix.exs"), "defmodule M do\n  use Mix.Project\n  def project, do: [app: :m, version: \"0.1.0\"]\nend\n")
    repo
  end

  defp git_init(repo) do
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@test"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "test"])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:org/repo.git"])
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-qm", "init"])
    :ok
  end

  defp check(results, id), do: Enum.find(results["checks"], &(&1["id"] == id))

  # ── Healthy repo ─────────────────────────────────────────────────────────

  test "full bot passes all required checks", %{root: root} do
    repo = build_full_bot(root)
    {:ok, results} = Checklist.run(repo, root: root)

    assert results["verdict"] == "healthy"
    assert results["summary"]["fail"] == 0
    assert check(results, "prod_exs")["status"] == "pass"
    assert check(results, "mix_lock")["status"] == "pass"
    assert check(results, "release")["status"] == "pass"
    assert check(results, "makefile")["status"] == "pass"
    assert check(results, "version")["status"] == "pass"
    assert check(results, "git_repo")["status"] == "pass"
    assert check(results, "runtime_mix")["status"] == "pass"
  end

  test "checks are shaped correctly", %{root: root} do
    repo = build_full_bot(root)
    {:ok, results} = Checklist.run(repo, root: root)

    for c <- results["checks"] do
      assert MapSet.member?(MapSet.new(["pass", "fail", "warn", "skip"]), c["status"])
      assert c["id"]
      assert c["severity"] in ["required", "warn"]
      assert is_binary(c["detail"])
    end
  end

  # ── Broken repo ──────────────────────────────────────────────────────────

  test "skeleton bot fails required checks with verdict failing", %{root: root} do
    repo = build_broken_bot(root)
    {:ok, results} = Checklist.run(repo, root: root)

    assert results["verdict"] == "failing"
    assert check(results, "prod_exs")["status"] == "fail"
    assert check(results, "makefile")["status"] == "fail"
    assert check(results, "mix_lock")["status"] == "fail"
    assert results["summary"]["fail"] >= 3
  end

  # -- prod_exs honesty: prod.exs is only required for unconditional imports --

  test "guarded per-env import without prod.exs passes", %{root: root} do
    repo = Path.join(root, "bot_army_guarded")
    File.mkdir_p!(Path.join(repo, "config"))
    File.write!(Path.join(repo, "config/config.exs"), """
import Config

env_config = "\#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
""")
    {:ok, results} = Checklist.run(repo, root: root)

    c = check(results, "prod_exs")
    assert c["status"] == "pass"
    assert c["detail"] =~ "guarded"
  end

  test "File.exists?-guarded Mix.env import without prod.exs passes", %{root: root} do
    repo = Path.join(root, "bot_army_guarded2")
    File.mkdir_p!(Path.join(repo, "config"))
    File.write!(Path.join(repo, "config/config.exs"), """
import Config

if File.exists?("config/\#{Mix.env()}.exs") do
  import_config "\#{Mix.env()}.exs"
end
""")
    {:ok, results} = Checklist.run(repo, root: root)

    assert check(results, "prod_exs")["status"] == "pass"
  end

  test "commented-out per-env import without prod.exs passes", %{root: root} do
    repo = Path.join(root, "bot_army_commented")
    File.mkdir_p!(Path.join(repo, "config"))
    File.write!(Path.join(repo, "config/config.exs"), """
import Config

# import_config "\#{config_env()}.exs", which would raise for :dev.
""")
    {:ok, results} = Checklist.run(repo, root: root)

    assert check(results, "prod_exs")["status"] == "pass"
    assert check(results, "prod_exs")["detail"] =~ "no per-env import"
  end

  test "no config.exs at all passes prod_exs", %{root: root} do
    repo = build_broken_bot(root, "bot_army_noconfig")

    # Remove the fixture's config.exs so the repo has no config dir at all
    File.rm!(Path.join(repo, "config/config.exs"))
    File.rmdir!(Path.join(repo, "config"))
    {:ok, results} = Checklist.run(repo, root: root)

    assert check(results, "prod_exs")["status"] == "pass"
    assert check(results, "prod_exs")["detail"] =~ "nothing imports"
  end

  test "missing release block fails", %{root: root} do
    repo = build_full_bot(root)

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule BotFull.MixProject do
      use Mix.Project
      def project, do: [app: :bot_full, version: "1.2.3"]
    end
    """)

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "release")["status"] == "fail"
  end

  test "non-semver version fails", %{root: root} do
    repo = build_full_bot(root)

    path = Path.join(repo, "mix.exs")
    src = File.read!(path)
    File.write!(path, String.replace(src, "1.2.3", "not-a-version"))

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "version")["status"] == "fail"
  end

  test "uncommitted mix.lock fails", %{root: root} do
    repo = build_full_bot(root)
    File.write!(Path.join(repo, "mix.lock"), "%{\"changed\" => {}}")

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "mix_lock")["status"] == "fail"
    assert results["verdict"] == "failing"
  end

  # ── Warning checks ──────────────────────────────────────────────────────

  test "missing runtime.exs warns, missing README warns, dirty tree warns", %{root: root} do
    repo = build_full_bot(root)

    File.rm!(Path.join(repo, "config/runtime.exs"))
    File.rm!(Path.join(repo, "README.md"))
    File.write!(Path.join(repo, "UNCOMMITTED.txt"), "dirty")

    {:ok, results} = Checklist.run(repo, root: root)

    assert check(results, "runtime_exs")["status"] == "warn"
    assert check(results, "readme")["status"] == "warn"
    assert check(results, "tree_clean")["status"] == "warn"
    # Warnings alone → degraded, never failing
    assert results["verdict"] == "degraded"
  end

  test "hooks wired passes; shipped-but-unwired passes with remedy; absent warns", %{root: root} do
    repo = build_full_bot(root)
    File.mkdir_p!(Path.join(repo, "git-hooks"))
    File.write!(Path.join(repo, "git-hooks/pre-push"), "#!/bin/bash\n")
    {_, 0} = System.cmd("git", ["-C", repo, "config", "core.hooksPath", "git-hooks"])

    {:ok, wired} = Checklist.run(repo, root: root)
    assert check(wired, "git_hooks")["status"] == "pass"
    assert check(wired, "git_hooks")["detail"] =~ "hooks wired"

    # Fresh-clone state: hooks shipped but core.hooksPath never set. The
    # repo's job is shipping the hooks; wiring is operator state, so this
    # passes with the remedy in the detail instead of warning forever.
    {_, 0} = System.cmd("git", ["-C", repo, "config", "--unset", "core.hooksPath"])
    {:ok, unwired} = Checklist.run(repo, root: root)
    assert check(unwired, "git_hooks")["status"] == "pass"
    assert check(unwired, "git_hooks")["detail"] =~ "setup-hooks"

    # No hooks at all → the repo standard itself is unmet.
    File.rm_rf!(Path.join(repo, "git-hooks"))
    {:ok, absent} = Checklist.run(repo, root: root)
    assert check(absent, "git_hooks")["status"] == "warn"
    assert check(absent, "git_hooks")["detail"] =~ "ships no git hooks"
  end

  test "template-only tests warn", %{root: root} do
    repo = build_full_bot(root)
    File.rm!(Path.join(repo, "test/consumer_test.exs"))
    File.mkdir_p!(Path.join(repo, "test/bot_full"))
    File.write!(Path.join(repo, "test/bot_full/example_test.exs"), "# example\n")

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "tests")["status"] == "warn"
    assert String.contains?(check(results, "tests")["detail"], "template")
  end

  test "committed build artifact warns", %{root: root} do
    repo = build_full_bot(root)
    File.write!(Path.join(repo, "erl_crash.dump"), "dump")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-qm", "oops artifact"])

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "artifacts")["status"] == "warn"
  end

  test "runtime Mix. call in lib warns", %{root: root} do
    repo = build_full_bot(root)

    File.write!(Path.join(repo, "lib/bot/consumer.ex"), """
    defmodule BotFull.Consumer do
      def env, do: Mix.env()
    end
    """)

    {:ok, results} = Checklist.run(repo, root: root)
    assert check(results, "runtime_mix")["status"] == "warn"
  end

  test "catalog check finds entry when catalog supplied", %{root: root} do
    repo = build_full_bot(root)
    catalog = Path.join(root, "bots.json")
    File.write!(catalog, ~s({"bots": [{"name": "bot_army_full"}]}))

    {:ok, results} = Checklist.run(repo, root: root, catalog_path: catalog)
    assert check(results, "catalog")["status"] == "pass"

    {:ok, results2} = Checklist.run(repo, root: root)
    assert check(results2, "catalog")["status"] == "skip"
  end

  # ── Input safety ────────────────────────────────────────────────────────

  test "path outside root is rejected", %{root: root} do
    outside = System.tmp_dir!() |> Path.join("outside_#{:rand.uniform(999_999)}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, :outside_root} = Checklist.run(outside, root: root)
  end

  test "missing repo is not_found", %{root: root} do
    assert {:error, :not_found} = Checklist.run(Path.join(root, "nope"), root: root)
  end

  test "bare name resolves against root", %{root: root} do
    build_full_bot(root, "bot_army_named")
    {:ok, results} = Checklist.run("bot_army_named", root: root)
    assert results["verdict"] == "healthy"
  end
end