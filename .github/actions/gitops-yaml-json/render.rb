require 'yaml'
require 'json'
require 'pathname'
require 'fileutils'

source = Pathname.new(ENV.fetch('DECLARATION_SOURCE')).realpath
abort 'GitOps source must be YAML' unless %w[.yaml .yml].include?(source.extname.downcase)
output = Pathname.new(ENV.fetch('DECLARATION_OUTPUT')).expand_path
runner_temp = Pathname.new(ENV.fetch('RUNNER_TEMP')).realpath
FileUtils.mkdir_p(output.dirname)
parent = output.dirname.realpath
abort 'Derived JSON must remain under runner.temp' unless parent.to_s.start_with?(runner_temp.to_s + '/') || parent == runner_temp
abort 'Output must not be a symlink' if output.symlink?
abort 'Output must differ from source' if output == source
value = YAML.safe_load(source.read, aliases: false)
abort 'GitOps declaration must be a mapping' unless value.is_a?(Hash)
File.write(output, JSON.generate(value) + "\n", perm: 0o600)
