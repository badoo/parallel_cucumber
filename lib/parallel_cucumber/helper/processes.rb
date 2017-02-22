module ParallelCucumber
  module Helper
    module Processes
      class << self
        def ps_tree
          `ps -ax -o ppid= -o pid= -o lstart= -o command=`
            .each_line.map { |l| l.strip.split(/ +/, 3) }.to_a
            .each_with_object({}) do |(ppid, pid, signature), tree|
            (tree[pid] ||= { children: [] })[:signature] = signature
            (tree[ppid] ||= { children: [] })[:children] << pid
          end
        end

        def kill_tree(sig, root, tree = nil, old_tree = nil)
          descendants(root, tree, old_tree) do |pid, node|
            begin
              puts "Killing #{node}"
              Process.kill(sig, pid.to_i)
            rescue Errno::ESRCH
              nil # It's gone already? Hurrah!
            end
          end
          # Let's kill pid unconditionally: descendants will go astray once reparented.
          begin
            puts "Killing #{root} just in case"
            Process.kill(sig, root.to_i)
          rescue Errno::ESRCH
            nil # It's gone already? Hurrah!
          end
        end

        def all_pids_dead?(root, tree = nil, old_tree = nil)
          # Note: returns from THIS function as well as descendants: short-circuit evaluation if any descendants remain.
          descendants(root, tree, old_tree) { return false }
          true
        end

        # Walks old_tree, and yields all processes (alive or dead) that match the pid, start time, and command in
        # the new tree. Note that this will fumble children created since old_tree was created, but this thing is
        # riddled with race conditions anyway.
        def descendants(pid, tree = nil, old_tree = nil, &block)
          tree ||= ps_tree
          old_tree ||= tree
          old_tree_node = old_tree[pid]
          unless old_tree_node
            warn "== old tree node went missing - skipping subtree: #{pid}"
            return
          end
          old_tree_node.fetch(:children, []).each { |c| descendants(c, tree, old_tree, &block) }
          yield(pid, old_tree_node) if tree[pid] && (tree[pid][:signature] == old_tree_node[:signature])
        end
      end
    end
  end
end
