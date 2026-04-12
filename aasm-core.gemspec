require_relative 'lib/aasm/core/version'

Gem::Specification.new do |spec|
  spec.name    = 'aasm-core'
  spec.version = AASM::Core::VERSION
  spec.authors = ['yash-srivastava19']

  spec.summary     = 'Drop-in AASM extension for business-critical state machines'
  spec.description = <<~DESC
    AASM::Core fixes four correctness problems in vanilla AASM that matter in
    financial and other business-critical systems:

      1. after_commit fires after the REAL outermost transaction commit, not
         inside it (vanilla AASM fires at SAVEPOINT release).
      2. Guards run before before-hooks — a failed guard never triggers side
         effects.
      3. State column bypass is blocked on all three vectors: direct assignment,
         update!, and update_columns.
      4. Every successful transition is logged atomically to a {Model}Transition
         table in the same transaction as the state column update.

    Developer API: one line per model — include AASM::Core.
  DESC

  spec.homepage              = 'https://github.com/yash-srivastava19/aasm-core'
  spec.license               = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md'].select { |f| File.file?(f) }

  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'aasm',                    '~> 5.5'
  spec.add_dependency 'activerecord',            '~> 7.1'
  spec.add_dependency 'after_commit_everywhere', '~> 1.0'

  # Development dependencies
  spec.add_development_dependency 'rspec',  '~> 3.13'
  spec.add_development_dependency 'sqlite3', '~> 1.7'
end
