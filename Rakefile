require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "tools"
  t.libs << "simulator"
  t.libs << "test"
  t.test_files = FileList["test/test_*.rb"]
end

desc "Start mruby/c on PLC console"
task :console do
  system("cmd /c chcp 65001 >nul && ruby tools/console.rb")
end

task default: :test
