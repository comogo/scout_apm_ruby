# A TrackedRequest is a stack of layers, where completed layers (go into, then
# come out of a layer) are forgotten as they finish. Layers are attached to
# their children as the process goes, building a tree structure within the
# layer objects. When the last layer is finished (hence the whole request is
# finished) it hands the root layer off to be recorded.

module ScoutApm
  class TrackedRequest
    # Context is application defined extra information.  (ie, which user, what
    # is their email/ip, what plan are they on, what locale are they using,
    # etc) See documentation for examples on how to set this from a
    # before_filter
    attr_reader :context

    # The first layer registered with this request. All other layers will be
    # children of this layer.
    attr_reader :root_layer

    # As we go through a request, instrumentation can mark more general data into the Request
    # Known Keys:
    #   :uri - the full URI requested by the user
    #   :queue_latency - how long a background Job spent in the queue before starting processing
    attr_reader :annotations

    # Headers as recorded by rails
    # Can be nil if we never reach a Rails Controller
    attr_reader :headers

    # What kind of request is this? A trace of a web request, or a background job?
    # Use job! and web! to set, and job? and web? to query
    attr_reader :request_type

    # This maintains a lookup hash of Layer names and call counts. It's used to trigger fetching a backtrace on n+1 calls.
    # Note that layer names might not be Strings - can alse be Utils::ActiveRecordMetricName. Also, this would fail for layers
    # with same names across multiple types.
    attr_accessor :call_counts

    BACKTRACE_THRESHOLD = 0.5 # the minimum threshold in seconds to record the backtrace for a metric.

    def initialize
      @layers = []
      @call_counts = Hash.new { |h, k| h[k] = CallSet.new }
      @annotations = {}
      @ignoring_children = false
      @context = Context.new
      @root_layer = nil
      @error = false
    end

    def start_layer(layer)
      if ignoring_children?
        return
      end

      start_request(layer) unless @root_layer
      update_call_counts!(layer)
      @layers[-1].add_child(layer) if @layers.any?
      @layers.push(layer)
    end

    def stop_layer
      return if ignoring_children?

      layer = @layers.pop
      layer.record_stop_time!

      if capture_backtrace?(layer)
        layer.capture_backtrace!
      end

      if finalized?
        stop_request
      end
    end

    BACKTRACE_BLACKLIST = ["Controller", "Job"]
    def capture_backtrace?(layer)
      # Never capture backtraces for this kind of layer. The backtrace will
      # always be 100% framework code.
      return false if BACKTRACE_BLACKLIST.include?(layer.type)

      # Only capture backtraces if we're in a real "request". Otherwise we
      # can spend lot of time capturing backtraces from the internals of
      # Sidekiq, only to throw them away immediately.
      return false unless (web? || job?)

      # Capture any individually slow layer.
      return true if layer.total_exclusive_time > BACKTRACE_THRESHOLD

      # Capture any layer that we've seen many times. Captures n+1 problems
      return true if @call_counts[layer.name].capture_backtrace?

      # Don't capture otherwise
      false
    end

    # Maintains a lookup Hash of call counts by layer name. Used to determine if we should capture a backtrace.
    def update_call_counts!(layer)
      @call_counts[layer.name].update!(layer.desc)
    end

    ###################################
    # Request Lifecycle
    ###################################

    # Are we finished with this request?
    # We're done if we have no layers left after popping one off
    def finalized?
      @layers.none?
    end

    # Run at the beginning of the whole request
    #
    # * Capture the first layer as the root_layer
    def start_request(layer)
      @root_layer = layer unless @root_layer # capture root layer
    end

    # Run at the end of the whole request
    #
    # * Send the request off to be stored
    def stop_request
      record!
    end

    ###################################
    # Annotations
    ###################################

    # As we learn things about this request, we can add data here.
    # For instance, when we know where Rails routed this request to, we can store that scope info.
    # Or as soon as we know which URI it was directed at, we can store that.
    #
    # This data is internal to ScoutApm, to add custom information, use the Context api.
    def annotate_request(hsh)
      @annotations.merge!(hsh)
    end

    # This request had an exception.  Mark it down as an error
    def error!
      @error = true
    end

    def error?
      @error
    end

    def set_headers(headers)
      @headers = headers
    end

    def job!
      @request_type = "job"
    end

    def job?
      request_type == "job"
    end

    def web!
      @request_type = "web"
    end

    def web?
      request_type == "web"
    end

    ###################################
    # Persist the Request
    ###################################

    # Convert this request to the appropriate structure, then report it into
    # the peristent Store object
    def record!
      @recorded = true

      # Update immediate and long-term histograms for both job and web requests
      if unique_name != :unknown
        ScoutApm::Agent.instance.request_histograms.add(unique_name, root_layer.total_call_time)
        ScoutApm::Agent.instance.request_histograms_by_time[ScoutApm::Agent.instance.store.current_timestamp].
          add(unique_name, root_layer.total_call_time)
      end

      metrics = LayerConverters::MetricConverter.new(self).call
      ScoutApm::Agent.instance.store.track!(metrics)

      error_metrics = LayerConverters::ErrorConverter.new(self).call
      ScoutApm::Agent.instance.store.track!(error_metrics)

      if web?
        # Don't #call this - that's the job of the ScoredItemSet later.
        slow_converter = LayerConverters::SlowRequestConverter.new(self)
        ScoutApm::Agent.instance.store.track_slow_transaction!(slow_converter)

        queue_time_metrics = LayerConverters::RequestQueueTimeConverter.new(self).call
        ScoutApm::Agent.instance.store.track!(queue_time_metrics)
      end

      if job?
        job_metrics = LayerConverters::JobConverter.new(self).call
        ScoutApm::Agent.instance.store.track_job!(job_metrics)

        job_converter = LayerConverters::SlowJobConverter.new(self)
        ScoutApm::Agent.instance.store.track_slow_job!(job_converter)
      end
    end

    # Only call this after the request is complete
    def unique_name
      @unique_name ||= begin
                         scope_layer = LayerConverters::ConverterBase.new(self).scope_layer
                         if scope_layer
                           scope_layer.legacy_metric_name
                         else
                           :unknown
                         end
                       end
    end

    # Have we already persisted this request?
    # Used to know when we should just create a new one (don't attempt to add
    # data to an already-recorded request). See RequestManager
    def recorded?
      @recorded
    end

    ###################################
    # Ignoring Children
    ###################################

    # Enable this when you would otherwise double track something interesting.
    # This came up when we implemented InfluxDB instrumentation, which is more
    # specific, and useful than the fact that InfluxDB happens to use Net::HTTP
    # internally
    #
    # When enabled, new layers won't be added to the current Request.
    #
    # Do not forget to turn if off when leaving a layer, it is the
    # instrumentation's task to do that.

    def ignore_children!
      @ignoring_children = true
    end

    def acknowledge_children!
      @ignoring_children = false
    end

    def ignoring_children?
      @ignoring_children
    end
  end
end
