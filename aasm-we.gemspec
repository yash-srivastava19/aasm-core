require_relative 'lib/aasm/version'

Gem::Specification.new do |spec|
  spec.name    = 'aasm-we'
  spec.version = AASM::VERSION
  spec.authors = ['yash-srivastava19']

  spec.summary     = 'Fork of AASM with correctness fixes for business-critical state machines'
  spec.description = <<~DESC
    aasm-we is a hard fork of the aasm gem (forked at 5.5.2) that integrates
    four correctness fixes directly into the state machine internals:

      1. Guards run before before-hooks — a failed guard never triggers side
         effects such as fee deductions or emails.
      2. after_commit fires after the REAL outermost transaction commit via
         after_commit_everywhere (not inside a SAVEPOINT).
      3. Direct state column assignment is blocked by default on all three
         vectors: setter, update!, and update_columns.
      4. Every successful transition is logged atomically to a {Model}Transition
         table in the same transaction as the state column update.

    Drop-in replacement for the aasm gem — same DSL, same API.
  DESC

  spec.homepage              = 'https://github.com/yash-srivastava19/aasm-we'
  spec.license               = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files         = Dir['lib/**/*.rb', 'LICENSE'].select { |f| File.file?(f) }
  spec.require_paths = ['lib']

  # Runtime dependencies (this gem IS aasm — no dependency on the original)
  spec.add_dependency 'concurrent-ruby',         '~> 1.0'
  spec.add_dependency 'activerecord',            '~> 7.1'
  spec.add_dependency 'after_commit_everywhere', '~> 1.0'

  # Development dependencies
  spec.add_development_dependency 'rspec',  '~> 3.13'
  spec.add_development_dependency 'sqlite3', '~> 1.7'
end
