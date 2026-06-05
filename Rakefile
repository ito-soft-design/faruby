require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "tools"
  t.libs << "simulator"
  t.libs << "test"
  t.test_files = FileList["test/test_*.rb"]
end

task default: :test
