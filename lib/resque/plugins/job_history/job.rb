# frozen_string_literal: true

require "active_support/core_ext/hash"

module Resque
  module Plugins
    module JobHistory
      # a class encompassing a single job.
      class Job < HistoryDetails
        attr_accessor :job_id

        def initialize(class_name, job_id)
          super(class_name)

          @stored_values = nil
          @job_id        = job_id
        end

        def job_key
          "#{job_history_base_key}.#{job_id}"
        end

        def worker_host
          stored_values[:hostname]
        end

        def worker_pid
          stored_values[:pid]
        end

        def start_time
          stored_values[:start_time].try(:to_time)
        end

        def finished?
          stored_values[:end_time].present?
        end

        def succeeded?
          error.blank?
        end

        def duration
          (end_time || Time.now) - start_time
        end

        def end_time
          stored_values[:end_time].try(:to_time)
        end

        def args
          decode_args(stored_values[:args])
        end

        def uncompressed_args
          return args if described_class.blank?
          return args unless described_class.singleton_class.included_modules.map(&:name).include?("Resque::Plugins::Compressible")
          return args unless described_class.compressed?(args)

          described_class.uncompressed_args(args.first[:payload] || args.first["payload"])
        end

        def error
          stored_values[:error]
        end

        def start(*args)
          num_jobs = running_jobs.add_job(job_id, class_name)
          linear_jobs.add_job(job_id, class_name) unless class_exclude_from_linear_history

          record_job_start(*args)
          record_num_jobs(num_jobs)

          self
        end

        def finish
          redis.hset(job_key, "end_time", Time.now.utc.to_s)

          finished_jobs.add_job(job_id, class_name)
          running_jobs.remove_job(job_id)

          reset

          self
        end

        def failed(exception)
          redis.hset(job_key, "error", exception_message(exception))
          redis.incr(total_failed_key)

          finish
        end

        def cancel
          redis.hset(job_key,
                     "error",
                     "Unknown - Job failed to signal ending after the configured purge time or "\
                       "was canceled manually.")
          redis.incr(total_failed_key)

          finish
        end

        def kill
          puts "Request to kill #{worker_host}:#{worker_pid}"
          return false unless worker_pid.to_i.positive?

          redis.lpush("cutting_block_#{worker_host}", worker_pid) rescue false
          redis.expire("cutting_block_#{worker_host}", 60) # 1 minute
        end

        def retry
          return unless described_class

          Resque.enqueue described_class, *args
        end

        def safe_purge
          return if running_jobs.includes_job?(job_id)
          return if finished_jobs.includes_job?(job_id)
          return if linear_jobs.includes_job?(job_id)

          purge
        end

        def purge
          # To keep the counts honest...
          cancel unless finished?

          remove_from_job_lists

          redis.del(job_key)

          reset
        end

        private

        def exception_message(exception)
          if exception.is_a?(Resque::DirtyExit)
            "#{exception.message}\n\n#{exception.process_status.to_s}".strip
          else
            exception.message
          end
        end

        def remove_from_job_lists
          running_jobs.remove_job(job_id)
          finished_jobs.remove_job(job_id)
          linear_jobs.remove_job(job_id)
        end

        def record_job_start(*args)
          hostname = `hostname`[0..-2]
          pid = Process.pid

          redis.hset(job_key, "start_time", Time.now.utc.to_s)
          redis.hset(job_key, "args", encode_args(*args))
          redis.hset(job_key, "hostname", hostname)
          redis.hset(job_key, "pid", pid)

          reset
        end

        def stored_values
          unless @stored_values
            @stored_values = redis.hgetall(job_key).with_indifferent_access
          end

          @stored_values
        end

        def encode_args(*args)
          Resque.encode(args)
        end

        def decode_args(args_string)
          Resque.decode(args_string)
        end

        def record_num_jobs(num_jobs)
          if redis.get(max_running_key).to_i < num_jobs
            redis.set(max_running_key, num_jobs)
          end

          return unless num_jobs >= class_history_len

          clean_old_running_jobs
        end

        def reset
          @stored_values = nil
        end
      end
    end
  end
end
