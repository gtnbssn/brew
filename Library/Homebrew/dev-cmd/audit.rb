# typed: true
# frozen_string_literal: true

require "formula"
require "formula_versions"
require "utils/curl"
require "utils/github/actions"
require "utils/shared_audits"
require "utils/spdx"
require "extend/ENV"
require "formula_cellar_checks"
require "cmd/search"
require "style"
require "date"
require "missing_formula"
require "digest"
require "cli/parser"
require "json"
require "formula_auditor"
require "tap_auditor"

module Homebrew
  sig { returns(CLI::Parser) }
  def self.audit_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Check <formula> for Homebrew coding style violations. This should be run before
        submitting a new formula or cask. If no <formula>|<cask> are provided, check all
        locally available formulae and casks and skip style checks. Will exit with a
        non-zero status if any errors are found.
      EOS
      flag   "--os=",
             description: "Audit the given operating system. (Pass `all` to audit all operating systems.)"
      flag   "--arch=",
             description: "Audit the given CPU architecture. (Pass `all` to audit all architectures.)"
      switch "--strict",
             description: "Run additional, stricter style checks."
      switch "--git",
             description: "Run additional, slower style checks that navigate the Git repository."
      switch "--online",
             description: "Run additional, slower style checks that require a network connection."
      switch "--installed",
             description: "Only check formulae and casks that are currently installed."
      switch "--eval-all",
             description: "Evaluate all available formulae and casks, whether installed or not, to audit them. " \
                          "Implied if `HOMEBREW_EVAL_ALL` is set."
      switch "--all",
             hidden: true
      switch "--new", "--new-formula", "--new-cask",
             description: "Run various additional style checks to determine if a new formula or cask is eligible " \
                          "for Homebrew. This should be used when creating new formula and implies " \
                          "`--strict` and `--online`."
      switch "--[no-]appcast",
             description: "Audit the appcast.",
             replacement: false
      switch "--[no-]signing",
             description: "Audit for signed apps, which are required on ARM"
      switch "--token-conflicts",
             description: "Audit for token conflicts."
      flag   "--tap=",
             description: "Check the formulae within the given tap, specified as <user>`/`<repo>."
      switch "--fix",
             description: "Fix style violations automatically using RuboCop's auto-correct feature."
      switch "--display-cop-names",
             description: "Include the RuboCop cop name for each violation in the output. This is the default.",
             hidden:      true
      switch "--display-filename",
             description: "Prefix every line of output with the file or formula name being audited, to " \
                          "make output easy to grep."
      switch "--display-failures-only",
             description: "Only display casks that fail the audit. This is the default for formulae and casks.",
             hidden:      true
      switch "--skip-style",
             description: "Skip running non-RuboCop style checks. Useful if you plan on running " \
                          "`brew style` separately. Enabled by default unless a formula is specified by name."
      switch "-D", "--audit-debug",
             description: "Enable debugging and profiling of audit methods."
      comma_array "--only",
                  description: "Specify a comma-separated <method> list to only run the methods named " \
                               "`audit_`<method>."
      comma_array "--except",
                  description: "Specify a comma-separated <method> list to skip running the methods named " \
                               "`audit_`<method>."
      comma_array "--only-cops",
                  description: "Specify a comma-separated <cops> list to check for violations of only the listed " \
                               "RuboCop cops."
      comma_array "--except-cops",
                  description: "Specify a comma-separated <cops> list to skip checking for violations of the " \
                               "listed RuboCop cops."
      switch "--formula", "--formulae",
             description: "Treat all named arguments as formulae."
      switch "--cask", "--casks",
             description: "Treat all named arguments as casks."

      conflicts "--only", "--except"
      conflicts "--only-cops", "--except-cops", "--strict"
      conflicts "--only-cops", "--except-cops", "--only"
      conflicts "--formula", "--cask"
      conflicts "--installed", "--all"

      named_args [:formula, :cask], without_api: true
    end
  end

  sig { void }
  def self.audit
    args = audit_args.parse

    Formulary.enable_factory_cache!

    os_arch_combinations = args.os_arch_combinations

    Homebrew.auditing = true
    inject_dump_stats!(FormulaAuditor, /^audit_/) if args.audit_debug?

    new_formula = args.new_formula?
    strict = new_formula || args.strict?
    online = new_formula || args.online?
    tap_audit = args.tap.present?
    skip_style = args.skip_style? || args.no_named? || tap_audit
    no_named_args = T.let(false, T::Boolean)

    ENV.activate_extensions!
    ENV.setup_build_environment

    audit_formulae, audit_casks = Homebrew.with_no_api_env do # audit requires full Ruby source
      if args.tap
        Tap.fetch(args.tap).then do |tap|
          [
            tap.formula_names.map { |name| Formula[name] },
            tap.cask_files.map { |path| Cask::CaskLoader.load(path) },
          ]
        end
      elsif args.installed?
        no_named_args = true
        [Formula.installed, Cask::Caskroom.casks]
      elsif args.no_named?
        if !args.eval_all? && !Homebrew::EnvConfig.eval_all?
          odisabled "brew audit",
                    "brew audit --eval-all or HOMEBREW_EVAL_ALL"
        end
        no_named_args = true
        [Formula.all, Cask::Cask.all]
      else
        if args.named.any? { |named_arg| named_arg.end_with?(".rb") }
          odeprecated "brew audit [path ...]",
                      "brew audit [name ...]"
        end

        args.named.to_formulae_and_casks
            .partition { |formula_or_cask| formula_or_cask.is_a?(Formula) }
      end
    end

    if audit_formulae.empty? && audit_casks.empty? && !args.tap
      ofail "No matching formulae or casks to audit!"
      return
    end

    style_files = args.named.to_paths unless skip_style

    only_cops = args.only_cops
    except_cops = args.except_cops
    style_options = { fix: args.fix?, debug: args.debug?, verbose: args.verbose? }

    if only_cops
      style_options[:only_cops] = only_cops
    elsif args.new_formula?
      nil
    elsif except_cops
      style_options[:except_cops] = except_cops
    elsif !strict
      style_options[:except_cops] = [:FormulaAuditStrict]
    end

    # Run tap audits first
    tap_problems = Tap.each_with_object({}) do |tap, problems|
      next if args.tap && tap != args.tap

      ta = TapAuditor.new(tap, strict: args.strict?)
      ta.audit

      problems[[tap.name, tap.path]] = ta.problems if ta.problems.any?
    end

    # Check style in a single batch run up front for performance
    style_offenses = Style.check_style_json(style_files, **style_options) if style_files
    # load licenses
    spdx_license_data = SPDX.license_data
    spdx_exception_data = SPDX.exception_data

    formula_problems = audit_formulae.sort.each_with_object({}) do |f, problems|
      path = f.path

      only = only_cops ? ["style"] : args.only
      options = {
        new_formula:         new_formula,
        strict:              strict,
        online:              online,
        git:                 args.git?,
        only:                only,
        except:              args.except,
        spdx_license_data:   spdx_license_data,
        spdx_exception_data: spdx_exception_data,
        style_offenses:      style_offenses&.for_path(f.path),
        tap_audit:           tap_audit,
      }.compact

      errors = os_arch_combinations.flat_map do |os, arch|
        SimulateSystem.with os: os, arch: arch do
          odebug "Auditing Formula #{f} on os #{os} and arch #{arch}"

          Formulary.clear_cache

          audit_proc = proc { FormulaAuditor.new(Formulary.factory(path), **options).tap(&:audit) }

          # Audit requires full Ruby source so disable API.
          # We shouldn't do this for taps however so that we don't unnecessarily require a full Homebrew/core clone.
          fa = if f.core_formula?
            Homebrew.with_no_api_env(&audit_proc)
          else
            audit_proc.call
          end

          fa.problems + fa.new_formula_problems
        end
      end.uniq

      problems[[f.full_name, path]] = errors if errors.any?
    end

    if audit_casks.any?
      require "cask/auditor"

      if args.display_failures_only?
        odeprecated "`brew audit <cask> --display-failures-only`", "`brew audit <cask>` without the argument"
      end
    end

    cask_problems = audit_casks.each_with_object({}) do |cask, problems|
      path = cask.sourcefile_path

      errors = os_arch_combinations.flat_map do |os, arch|
        next [] if os == :linux

        SimulateSystem.with os: os, arch: arch do
          odebug "Auditing Cask #{cask} on os #{os} and arch #{arch}"

          Cask::Auditor.audit(
            Cask::CaskLoader.load(path),
            # For switches, we add `|| nil` so that `nil` will be passed
            # instead of `false` if they aren't set.
            # This way, we can distinguish between "not set" and "set to false".
            audit_online:          (args.online? || nil),
            audit_strict:          (args.strict? || nil),

            # No need for `|| nil` for `--[no-]signing`
            # because boolean switches are already `nil` if not passed
            audit_signing:         args.signing?,
            audit_new_cask:        (args.new_cask? || nil),
            audit_token_conflicts: (args.token_conflicts? || nil),
            quarantine:            true,
            any_named_args:        !no_named_args,
            only:                  args.only,
            except:                args.except,
          ).to_a
        end
      end.uniq

      problems[[cask.full_name, path]] = errors if errors.any?
    end

    print_problems(tap_problems, display_filename: args.display_filename?)
    print_problems(formula_problems, display_filename: args.display_filename?)
    print_problems(cask_problems, display_filename: args.display_filename?)

    tap_count = tap_problems.keys.count
    formula_count = formula_problems.keys.count
    cask_count = cask_problems.keys.count

    corrected_problem_count = (formula_problems.values + cask_problems.values)
                              .sum { |problems| problems.count { |problem| problem.fetch(:corrected) } }

    tap_problem_count = tap_problems.sum { |_, problems| problems.count }
    formula_problem_count = formula_problems.sum { |_, problems| problems.count }
    cask_problem_count = cask_problems.sum { |_, problems| problems.count }
    total_problems_count = formula_problem_count + cask_problem_count + tap_problem_count

    if total_problems_count.positive?
      errors_summary = Utils.pluralize("problem", total_problems_count, include_count: true)

      error_sources = []
      if formula_count.positive?
        error_sources << Utils.pluralize("formula", formula_count, plural: "e", include_count: true)
      end
      error_sources << Utils.pluralize("cask", cask_count, include_count: true) if cask_count.positive?
      error_sources << Utils.pluralize("tap", tap_count, include_count: true) if tap_count.positive?

      errors_summary += " in #{error_sources.to_sentence}" if error_sources.any?

      errors_summary += " detected"

      if corrected_problem_count.positive?
        errors_summary += ", #{Utils.pluralize("problem", corrected_problem_count, include_count: true)} corrected"
      end

      ofail "#{errors_summary}."
    end

    return unless ENV["GITHUB_ACTIONS"]

    annotations = formula_problems.merge(cask_problems).flat_map do |(_, path), problems|
      problems.map do |problem|
        GitHub::Actions::Annotation.new(
          :error,
          problem[:message],
          file:   path,
          line:   problem[:location]&.line,
          column: problem[:location]&.column,
        )
      end
    end.compact

    annotations.each do |annotation|
      puts annotation if annotation.relevant?
    end
  end

  def self.print_problems(results, display_filename:)
    results.each do |(name, path), problems|
      problem_lines = format_problem_lines(problems)

      if display_filename
        problem_lines.each do |l|
          puts "#{path}: #{l}"
        end
      else
        puts name, problem_lines.map { |l| l.dup.prepend("  ") }
      end
    end
  end

  def self.format_problem_lines(problems)
    problems.map do |message:, location:, corrected:|
      status = " #{Formatter.success("[corrected]")}" if corrected
      location = "#{location.line&.to_s&.prepend("line ")}#{location.column&.to_s&.prepend(", col ")}: " if location
      "* #{location}#{message.chomp.gsub("\n", "\n    ")}#{status}"
    end
  end
end
