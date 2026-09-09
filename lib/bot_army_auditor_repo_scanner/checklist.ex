defmodule BotArmyAuditorRepoScanner.Checklist do
  @moduledoc """
  The bot-contract checklist runner.

  Runs a repo through the contract rules that were earned empirically by the
  Phase-4 pack matrix and the conformance/sre arcs:

    - `config/prod.exs` present          (MIX_ENV=prod release builds need it)
    - `mix.lock` present AND committed   (reproducible builds)
    - release defined in mix.exs         (`releases: [...]` with a `*_bot` name)
    - Makefile with `test:` + `publish-release:` targets
    - version parseable from mix.exs     (semver-ish X.Y.Z)
    - git repo with an `origin` remote

  Warnings (not failures):
    - git hooks wired (core.hooksPath + executable git-hooks/pre-push)
    - README.md present
    - config/runtime.exs present       (the env-var override chain)
    - real tests present               (template-only tests ⇒ warn)
    - working tree clean
    - no build artifacts committed     (erl_crash.dump, _build/, cover/)
    - no runtime `Mix.` calls in lib/  (Mix.env() is compile-time only)
    - catalog entry (only when a catalog path is supplied)

  Pure file-system + read-only git operations — the repo is mounted read-only
  into the container. Scans are triggered via `auditor.repo.scan` request/reply;
  every completed scan publishes an sre audit receipt (regardless of verdict)
  so the observability chain (audit_events + sre.audit.query) covers scans.
  """

  require Logger

  @version_regex ~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/

  @type check :: %{
          required(:id) => String.t(),
          required(:severity) => :required | :warn,
          required(:status) => :pass | :fail | :warn | :skip,
          required(:detail) => String.t()
        }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Runs the checklist against `repo_path`.

  Options:
    - `:root` - containment root; repo_path must live under it (default from
      env AUDITOR_REPO_ROOT, else "/repos"). Guards against path traversal.
    - `:catalog_path` - optional path to a bots.json catalog; when present
      (and readable) adds the catalog-entry check.

  Returns `{:ok, results}` where results carries `checks`, `summary`, `verdict`,
  or `{:error, reason}` when the path is missing/outside the root.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | :outside_root}
  def run(repo_path, opts \\ []) do
    root = Keyword.get(opts, :root, default_root())
    repo_path = resolve_path(repo_path, root)

    cond do
      containment_check(repo_path, root) == :error ->
        {:error, :outside_root}

      not File.dir?(repo_path) ->
        {:error, :not_found}

      true ->
        started_at = DateTime.utc_now() |> DateTime.to_iso8601()
        checks = run_checks(repo_path, opts)
        {:ok, build_results(repo_path, checks, started_at)}
    end
  end

  defp default_root, do: System.get_env("AUDITOR_REPO_ROOT", "/repos")

  defp resolve_path(repo_path, root) do
    if absolute?(repo_path) do
      Path.absname(repo_path)
    else
      # Bare name ("bot_army_sre") resolves against the containment root.
      Path.absname(Path.join(root, repo_path))
    end
  end

  defp absolute?("/" <> _), do: true
  defp absolute?(_), do: false

  defp containment_check(repo_path, root) do
    root_abs = Path.absname(root)

    if String.starts_with?(repo_path, root_abs <> "/") or repo_path == root_abs do
      :ok
    else
      :error
    end
  end

  # ── Check execution ─────────────────────────────────────────────────────

  defp run_checks(repo_path, opts) do
    Enum.concat([
      required_checks(repo_path),
      warn_checks(repo_path),
      catalog_check(repo_path, opts) |> List.wrap()
    ])
  end

  defp required_checks(repo_path) do
    [
      prod_exs_check(repo_path),
      mix_lock_check(repo_path),
      release_check(repo_path),
      makefile_check(repo_path),
      version_check(repo_path),
      git_repo_check(repo_path)
    ]
  end

  defp warn_checks(repo_path) do
    [
      git_hooks_check(repo_path),
      readme_check(repo_path),
      runtime_exs_check(repo_path),
      tests_check(repo_path),
      dirty_tree_check(repo_path),
      artifacts_check(repo_path),
      runtime_mix_check(repo_path)
    ]
  end

  # ── Required checks ─────────────────────────────────────────────────────

  # config/prod.exs is only a HARD requirement when config.exs imports a
  # per-env file unconditionally — `import_config "#{Mix.env()}.exs"` with no
  # File.exists?/File.regular? guard. The fleet standard is the guarded form
  # (prod/dev overrides are optional), so an unconditional import is the only
  # honest required-fail here.
  defp prod_exs_check(repo_path) do
    if File.regular?(Path.join(repo_path, "config/prod.exs")) do
      pass("prod_exs", "config/prod.exs present")
    else
      config = Path.join(repo_path, "config/config.exs")

      cond do
        not File.regular?(config) ->
          pass("prod_exs", "no config.exs — nothing imports per-env config, prod builds don't need config/prod.exs")

        true ->
          case per_env_import_kind(config) do
            :unconditional ->
              fail("prod_exs", "config.exs imports per-env config unconditionally — MIX_ENV=prod release builds fail without config/prod.exs")

            :guarded ->
              pass("prod_exs", "no config/prod.exs — per-env import is File.exists?-guarded, prod builds don't read it")

            :none ->
              pass("prod_exs", "no config/prod.exs — config.exs has no per-env import, prod builds don't read it")
          end
      end
    end
  end

  defp per_env_import_kind(config_path) do
    lines =
      config_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(fn line -> String.trim_leading(line) =~ ~r/^#/ end)
      |> Enum.with_index(1)

    import_lines =
      for {line, idx} <- lines,
          String.contains?(line, "import_config"),
          per_env_import?(line),
          do: {line, idx}

    cond do
      import_lines == [] -> :none
      Enum.all?(import_lines, fn {line, i} -> guarded_import?(i, lines) end) -> :guarded
      true -> :unconditional
    end
  end

  # Only per-env imports concern this check. A static
  # `import_config "runtime.exs"` (or "test.exs") is unconditional by design
  # and says nothing about config/prod.exs.
  defp per_env_import?(line) do
    String.contains?(line, "Mix.env()") or
      String.contains?(line, "config_env()") or
      String.contains?(line, "env_config")
  end

  # An import_config is "guarded" when File.exists?/File.regular? appears
  # within the 8 preceding meaningful lines (covers both the inline
  # `if File.exists?("config/...exs")` form and the two-step
  # `env_config = ...; if File.exists?(...)` form).
  defp guarded_import?(line_index, lines) do
    window_start = max(line_index - 8, 1)

    for {line, i} <- lines, i >= window_start and i < line_index do
      line
    end
    |> Enum.any?(fn line ->
      String.contains?(line, "File.exists?") or String.contains?(line, "File.regular?")
    end)
  end

  defp mix_lock_check(repo_path) do
    path = Path.join(repo_path, "mix.lock")

    cond do
      not File.regular?(path) ->
        fail("mix_lock", "mix.lock missing — builds are not reproducible")

      git_clean_file?(repo_path, "mix.lock") ->
        pass("mix_lock", "mix.lock committed and unmodified")

      true ->
        fail("mix_lock", "mix.lock missing from HEAD (untracked or modified) — builds are not reproducible")

      true ->
        fail("mix_lock", "mix.lock exists but is NOT committed to git")
    end
  end

  defp release_check(repo_path) do
    case read_mix_exs(repo_path) do
      {:ok, source} ->
        case Regex.run(~r/releases:\s*\[([^\]]*)\]/s, source) do
          [_, block] ->
            case Regex.run(~r/([a-z0-9_]+)_bot\s*:/, block) do
              [full, _name] ->
                pass("release", "OTP release defined: #{full}")

              nil ->
                fail("release", "mix.exs has releases: but no `<name>_bot:` release name")
            end

          nil ->
            fail("release", "mix.exs defines no releases: [ ... ] block")
        end

      :error ->
        fail("release", "mix.exs unreadable")
    end
  end

  defp makefile_check(repo_path) do
    makefile = Path.join(repo_path, "Makefile")

    cond do
      not File.regular?(makefile) ->
        fail("makefile", "Makefile missing — make targets are the only sanctioned way to run bot code")

      missing_target?(makefile, ~r/^test:/) ->
        fail("makefile", "Makefile has no `test:` target")

      missing_target?(makefile, ~r/^publish-release:/) ->
        fail("makefile", "Makefile has no `publish-release:` target")

      true ->
        pass("makefile", "Makefile with test: and publish-release: targets")
    end
  end

  defp missing_target?(makefile, regex) do
    makefile
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(fn line -> Regex.match?(regex, line) end)
    |> Kernel.not()
  end

  defp version_check(repo_path) do
    case read_mix_exs(repo_path) do
      {:ok, source} ->
        case Regex.run(~r/version:\s*"([^"]+)"/, source) do
          [_, version] ->
            if Regex.match?(@version_regex, version) do
              pass("version", "version #{version} parseable")
            else
              fail("version", "version #{inspect(version)} is not semver-ish (X.Y.Z)")
            end

          nil ->
            fail("version", "mix.exs has no version string")
        end

      :error ->
        fail("version", "mix.exs unreadable")
    end
  end

  defp git_repo_check(repo_path) do
    cond do
      not git?(repo_path) ->
        fail("git_repo", "not a git repository")

      true ->
        case git(repo_path, ["remote", "get-url", "origin"]) do
          {:ok, url} -> pass("git_repo", "git repo with origin: #{url |> String.trim() |> short_url()}")
          _ -> fail("git_repo", "git repo has no `origin` remote")
        end
    end
  end

  # ── Warn checks ─────────────────────────────────────────────────────────

  defp git_hooks_check(repo_path) do
    hooks_path =
      case git(repo_path, ["config", "core.hooksPath"]) do
        {:ok, out} -> String.trim(out)
        _ -> nil
      end

    pre_push = Path.join([repo_path, hooks_path || "git-hooks", "pre-push"])
    ships_hooks = File.regular?(Path.join(repo_path, "git-hooks/pre-push"))

    cond do
      # The repo's responsibility is SHIPPING the hooks; wiring core.hooksPath
      # is clone-local operator state (a fresh clone never has it set, so
      # demanding it here would warn forever on every clean checkout).
      is_nil(hooks_path) and ships_hooks ->
        pass(
          "git_hooks",
          "repo ships git-hooks/pre-push (run `make setup-hooks` after cloning to wire core.hooksPath)"
        )

      is_nil(hooks_path) ->
        warn("git_hooks", "repo ships no git hooks — add git-hooks/pre-push + a `make setup-hooks` target")

      File.regular?(pre_push) ->
        pass("git_hooks", "hooks wired: core.hooksPath=#{hooks_path}, pre-push present")

      true ->
        warn("git_hooks", "core.hooksPath=#{hooks_path} but no executable pre-push hook")
    end
  end

  defp readme_check(repo_path) do
    if File.regular?(Path.join(repo_path, "README.md")) do
      pass("readme", "README.md present")
    else
      warn("readme", "README.md missing")
    end
  end

  defp runtime_exs_check(repo_path) do
    if File.regular?(Path.join(repo_path, "config/runtime.exs")) do
      pass("runtime_exs", "config/runtime.exs present (env override chain)")
    else
      warn("runtime_exs", "config/runtime.exs missing — no boot-time env override chain")
    end
  end

  defp tests_check(repo_path) do
    test_files = list_test_files(repo_path)

    cond do
      test_files == [] ->
        warn("tests", "test/ has no *_test.exs files")

      only_example?(test_files) ->
        warn("tests", "template tests only (example_test.exs) — no real coverage")

      true ->
        pass("tests", "#{length(test_files)} test file(s)")
    end
  end

  defp only_example?(test_files) do
    Enum.all?(test_files, fn path ->
      String.contains?(path, "example_test.exs") or String.contains?(path, "skills/example")
    end)
  end

  defp dirty_tree_check(repo_path) do
    case git(repo_path, ["status", "--porcelain"]) do
      {:ok, ""} -> pass("tree_clean", "working tree clean")
      {:ok, out} -> warn("tree_clean", "uncommitted changes (#{count_lines(out)} files) — version drift risk")
      _ -> skip("tree_clean", "could not read git status (read-only mount?)")
    end
  end

  defp artifacts_check(repo_path) do
    case committed_files(repo_path) do
      {:ok, files} ->
        bad =
          files
          |> Enum.filter(fn f ->
            String.starts_with?(f, "_build/") or String.starts_with?(f, "cover/") or
              String.contains?(f, "erl_crash.dump")
          end)

        if bad == [] do
          pass("artifacts", "no build artifacts committed")
        else
          warn("artifacts", "build artifacts committed: #{Enum.take(bad, 3) |> Enum.join(", ")}")
        end

      _ ->
        skip("artifacts", "could not list committed files")
    end
  end

  defp runtime_mix_check(repo_path) do
    sources = lib_sources(repo_path)

    if sources == [] do
      skip("runtime_mix", "no lib/ sources found")
    else
      findings = runtime_mix_findings(repo_path)

      if Enum.empty?(findings) do
        pass("runtime_mix", "no runtime Mix calls in lib/ (#{length(sources)} sources scanned)")
      else
        {path, n} = hd(findings)

        warn(
          "runtime_mix",
          "runtime Mix call in lib/ (compile-time-only contract): #{rel_path(repo_path, path)}:#{n}"
        )
      end
    end
  end

  defp runtime_mix_findings(repo_path) do
    lib_sources(repo_path)
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> runtime_mix?(line) end)
      |> Enum.map(fn {_line, n} -> {path, n} end)
    end)
  end

  # The detector must not contain its own needle literally (it would flag
  # itself when scanning its own repo), so it is assembled from parts.
  @mix_call "Mix" <> "."
  @mix_call_quoted "`" <> "Mix" <> "."

  # A line uses Mix at runtime when it references the module but is neither a
  # module-attribute assignment (compile-time, e.g. the @env pattern) nor a
  # comment. use Mix.Project / defmodule lines are compile-time forms too.
  # Backtick-quoted mentions and bullet lines are prose (docstrings) — skipped.
  defp runtime_mix?(line) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "#") -> false
      String.starts_with?(trimmed, "-") or String.starts_with?(trimmed, "*") -> false
      String.contains?(trimmed, @mix_call_quoted) -> false
      String.contains?(trimmed, @mix_call) and String.starts_with?(trimmed, "@") -> false
      String.contains?(trimmed, "use Mix.Project") -> false
      String.contains?(trimmed, "defmodule") -> false
      String.contains?(trimmed, @mix_call) -> true
      true -> false
    end
  end



  # ── Catalog check ───────────────────────────────────────────────────────

  defp catalog_check(repo_path, opts) do
    catalog_path = Keyword.get(opts, :catalog_path)

    if is_binary(catalog_path) and File.regular?(catalog_path) do
      name = Path.basename(repo_path)

      case decode_catalog(catalog_path) do
        {:ok, entries} ->
          if catalog_has?(entries, name) do
            pass("catalog", "catalog entry present for #{name}")
          else
            warn("catalog", "#{name} not found in catalog (#{Path.basename(catalog_path)})")
          end

        :error ->
          skip("catalog", "catalog unreadable at #{catalog_path}")
      end
    else
      skip("catalog", "no catalog path supplied")
    end
  end

  defp decode_catalog(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"bots" => bots}} when is_list(bots) ->
            {:ok, Enum.map(bots, &entry_name/1) |> Enum.reject(&is_nil/1)}

          {:ok, bots} when is_list(bots) ->
            {:ok, Enum.map(bots, &entry_name/1) |> Enum.reject(&is_nil/1)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp entry_name(%{"name" => n}) when is_binary(n), do: n
  defp entry_name(%{"repo" => r}) when is_binary(r), do: r
  defp entry_name(_), do: nil

  # Catalog entries are typically "auditor_repo_scanner" while the repo dir
  # is "bot_army_auditor_repo_scanner" — compare with the bot_army_ prefix
  # stripped from both sides.
  defp catalog_has?(entries, name) do
    stripped = String.replace_prefix(name, "bot_army_", "")

    Enum.any?(entries, fn e ->
      String.replace_prefix(e, "bot_army_", "") == stripped
    end)
  end

  # ── Results assembly ────────────────────────────────────────────────────

  defp build_results(repo_path, checks, started_at) do
    :ok
    summary = %{
      "pass" => count(checks, :pass),
      "fail" => count(checks, :fail),
      "warn" => count(checks, :warn),
      "skip" => count(checks, :skip)
    }

    fails = count(checks, :fail)

    verdict =
      cond do
        fails > 0 -> "failing"
        count(checks, :warn) > 0 -> "degraded"
        true -> "healthy"
      end

    %{
      "repo" => repo_path,
      "name" => Path.basename(repo_path),
      "scanned_at" => started_at,
      "checks" => Enum.map(checks, &atomize_check/1),
      "summary" => summary,
      "verdict" => verdict,
      "score" => "#{summary["pass"]}/#{length(checks)} checks passed"
    }
  end

  defp atomize_check(%{id: id, severity: sev, status: st, detail: d}) do
    %{"id" => id, "severity" => to_string(sev), "status" => to_string(st), "detail" => d}
  end

  defp count(checks, status), do: Enum.count(checks, &(&1.status == status))

  # ── Check constructors ──────────────────────────────────────────────────

  defp pass(id, detail), do: check(id, :pass, detail)
  defp fail(id, detail), do: check(id, :fail, detail)
  defp warn(id, detail), do: check(id, :warn, detail)
  defp skip(id, detail), do: check(id, :skip, detail)

  defp check(id, status, detail) do
    %{id: id, severity: severity_for(id), status: status, detail: detail}
  end

  @required_ids ~w(prod_exs mix_lock release makefile version git_repo)
  defp severity_for(id) when id in @required_ids, do: :required
  defp severity_for(_), do: :warn

  # ── FS / git helpers (all read-only) ────────────────────────────────────

  defp read_mix_exs(repo_path) do
    case File.read(Path.join(repo_path, "mix.exs")) do
      {:ok, source} -> {:ok, source}
      _ -> :error
    end
  end

  defp git?(repo_path), do: File.dir?(Path.join(repo_path, ".git"))

  # A file counts as committed only when its working-tree content matches
  # HEAD (ls-files alone would call a modified-then-untouched lock "committed").
  defp git_clean_file?(repo_path, rel_path) do
    case git(repo_path, ["status", "--porcelain", "--", rel_path]) do
      {:ok, ""} -> true
      _ -> false
    end
  end

  defp committed_files(repo_path) do
    case git(repo_path, ["ls-files"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      err -> err
    end
  end

  defp list_test_files(repo_path) do
    test_dir = Path.join(repo_path, "test")

    if File.dir?(test_dir) do
      Path.wildcard(Path.join(test_dir, "**/*_test.exs"))
    else
      []
    end
  end

  defp lib_sources(repo_path) do
    lib_dir = Path.join(repo_path, "lib")

    if File.dir?(lib_dir) do
      # lib/mix/tasks is the standard home for CLI-only Mix tasks: they run
      # under `mix` on the host and are never part of the release runtime,
      # so Mix.* calls there honor the compile-time-only contract.
      Path.wildcard(Path.join(lib_dir, "**/*.ex"))
      |> Enum.reject(fn path ->
        String.contains?(path, "mix/tasks")
      end)
    else
      []
    end
  end

  defp rel_path(repo_path, path) do
    case Path.relative_to(path, repo_path) do
      ^path -> path
      rel -> rel
    end
  end

  defp count_lines(out) do
    out |> String.split("\n", trim: true) |> length()
  end

  defp short_url(url) do
    url
    |> String.replace_prefix("git@github.com:", "")
    |> String.replace_suffix(".git", "")
  end

  # git is invoked with read-only subcommands only (config --get semantics,
  # ls-files, status --porcelain, remote get-url). Safe on RO mounts.
  defp git(repo_path, args) do
    # --no-optional-locks: stage mounts repos/ read-only — plain `git status`
    # tries to refresh the index (needs .git/index.lock) and fails on a RO
    # mount. The flag keeps every invocation read-only by design.
    case System.cmd("git", ["--no-optional-locks", "-C", repo_path | args],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, out}
      {_err, _code} -> {:error, :git_failed}
    end
  rescue
    _ -> {:error, :git_unavailable}
  end
end