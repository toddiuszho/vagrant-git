begin
	require 'vagrant'
rescue LoadError
	raise 'The Vagrant Git plugin must be run within Vagrant.'
end

module VagrantGit
	module Ops
		class << self
			# Run the command, wait for exit and return the Process object.
			def run(cmd)
				pid = Process.fork { exec(cmd) }
				Process.waitpid(pid)
				return $?
			end

			def clone(target, path, opts = {})
				branch = opts[:branch]
				if branch.nil?
					return run("git clone '#{target}' '#{path}'")
				else
					return run("git clone -b '#{branch}' '#{target}' '#{path}'")
				end
			end
			def fetch(path)
				return run("cd '#{path}'; git fetch")
			end

			def pull(path, opts = {})
				branch = opts[:branch]
				if branch.nil?
					return run("cd '#{path}'; git fetch; git pull;")
				else
					return run("cd '#{path}'; git pull origin '#{branch}';")
				end
			end

			def submodule(path)
				return run("cd '#{path}' && git submodule update --init --recursive")
			end

			def set_upstream(path, target)
				return run("cd '#{path}'; git remote set-url origin '#{target}';")
			end
		end
	end

	class Plugin < Vagrant.plugin("2")
		name "vagrant git support"
		description "A vagrant plugin to allow checking out git repositories as part of vagrant tasks."

		config(:git) do
			Config
		end

		action_hook(self::ALL_ACTIONS) do |hook|
			hook.after(VagrantPlugins::ProviderVirtualBox::Action::Boot, HandleRepos)
		end
	end

	class HandleRepos
		# Action to either clone or pull git repos
		def initialize(app, env); end 

		def call(env)
			vm = env[:machine]
			vm.config.git.to_hash[:repos].each do |rc|
				if not rc.clone_in_host
					raise 'NotImplemented: clone_in_host=>false'
				end

				if File.exist? "#{rc.path}/.git"
					if rc.sync_on_load
						VagrantGit::Ops::fetch(rc.path)
						VagrantGit::Ops::pull(rc.path, {:branch => rc.branch})
					end
				else
					p = VagrantGit::Ops::clone(rc.target, rc.path, {:branch => rc.branch})
					if p.success? and rc.set_upstream
						vm.ui.info("Clone done - setting upstream of #{rc.path} to #{rc.set_upstream}")
						if not VagrantGit::Ops::set_upstream(rc.path, rc.set_upstream).success?
							vm.ui.error("WARNING: Failed to change upstream to #{rc.set_upstream} in #{rc.path}")
						end
					else
						vm.ui.error("WARNING: Failed to clone #{rc.target} into #{rc.path}")
					end
					if File.exist? "#{rc.path}/.gitmodules"
						p = VagrantGit::Ops::submodule(rc.path)
						if p.success?
							vm.ui.info("Checked out submodules.")
						else
							vm.ui.error("WARNING: Failed to check out submodules for #{path}")
						end
					end
				end
			end
		end
	end

	class RepoConfig
		# Config for a single repo
		# Assumes that the agent has permission to check out, or that it's public

		attr_accessor :target, :path, :clone_in_host, :branch, :sync_on_load, :set_upstream

		@@required = [:target, :path]

		def validate
			errors = {}
			if @target.nil?
				errors[:target] = ["target must not be nil."]
			end
			if @path.nil?
				errors[:path] = ["path must not be nil."]
			end
			errors
		end

		def finalize!
			if @clone_in_host.nil?
				@clone_in_host = true
			end
			if @sync_on_load.nil?
				@sync_on_load = false
			end
		end
	end

	class Config < Vagrant.plugin("2", :config)
		# Singleton for each VM
		@@repo_configs = []
		class << self
			attr_accessor :repo_configs
		end

		def to_hash
			{ :repos => @@repo_configs }
		end

		def add_repo
			# Yield a new repo config object to the config block
			rc = RepoConfig.new
			yield rc
			@@repo_configs.push rc
		end

		def validate(machine)
			errors = {}
			@@repo_configs.each_with_index do |rc, i|
				rc_errors = rc.validate
				if rc_errors.length > 0
					errors[i] = rc_errors
				end
			end
			errors
		end
		def finalize!
			@@repo_configs.each do |config|
				config.finalize!
			end
		end
	end
end
