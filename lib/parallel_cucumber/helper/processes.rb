require 'sys/proctable'
include Sys

module ParallelCucumber
  module Helper
    module Processes
      class << self
        def ps_tree
          ` ps -ax -o ppid= -o pid= -o lstart= -o command= `
            .each_line.map { |l| l.strip.split(/ +/, 3) }.to_a
            .each_with_object({}) do |(ppid, pid, signature), tree|
            (tree[pid] ||= { children: [] })[:signature] = signature
            (tree[ppid] ||= { children: [] })[:children] << pid
          end
        end

        def ps_tree_windows
          all_processes = ProcTable.ps
          groups = all_processes.group_by{ |x| x[:ppid] }
          groups.default = []

          build_tree =
            lambda do |parent|
              [[parent[:pid], parent[:comm]], groups[parent[:pid]].map(&build_tree)]
            end
          build_tree
        end

        def kill_tree(sig, root, tree = nil, old_tree = nil)
          tree = ps_tree_windows
          to_kill = []

          tree[root][1].to_a.flatten.each { |p| to_kill << p if p.is_a?(Fixnum) }

          to_kill.each do |p|
            begin
              Process.kill(Platform.windows? ? 9 : sig, p)
            rescue Errno::ESRCH
              nil # It's gone already? Hurrah!
            end
          end
        end


        def all_pids_dead?(root, tree = nil, old_tree = nil)
          all_processes = ProcTable.ps
          all_processes.any? { |p| p.ppid.to_s == pid }
=begin
          if Platform.windows?
            all_pids_dead_windows?
          else
            # Note: returns from THIS function as well as descendants: short-circuit evaluation.
            descendants(root, tree, old_tree) { return false }
            true
          end
=end
        end

        # Walks old_tree, and yields all processes (alive or dead) that match the pid, start time, and command in
        # the new tree. Note that this will fumble children created since old_tree was created, but this thing is
        # riddled with race conditions anyway.
        def descendants(pid, tree = nil, old_tree = nil, &block)
          tree ||= ps_tree
          old_tree ||= tree
          old_tree[pid][:children].each { |c| descendants(c, tree, old_tree, &block) }
          yield(pid) if tree[pid] && (tree[pid][:signature] == old_tree[pid][:signature])
        end
      end
    end
  end
end
