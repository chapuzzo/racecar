require "rdkafka"

module Racecar
  class Runner
    attr_reader :processor, :config, :logger

    def initialize(processor, config:, logger:, instrumenter: NullInstrumenter)
      @processor, @config, @logger = processor, config, logger
      @instrumenter = instrumenter
      @stop_requested = false
      Rdkafka::Config.logger = logger

      if processor.respond_to?(:statistics_callback)
        Rdkafka::Config.statistics_callback = processor.method(:statistics_callback).to_proc
      end
    end

    def run
      install_signal_handlers

      # When being in batch mode it might happen, that we send a commit before
      # returning the consumer.batch_poll method. To circumvent this we don't
      # autocommit but call commit after the whole batch was fetched. Because
      # synchronous commits are disabled by default there should almost be no
      # difference in performance.
      if processor.respond_to?(:process_batch)
        config.consumer << "enable.auto.commit=false"
      end

      consumer = ConsumerSet.new(config, logger)
      consumer.subscribe

      # Configure the consumer with a producer so it can produce messages and
      # with a consumer so that it can support advanced use-cases.
      processor.configure(
        producer:     producer,
        consumer:     consumer,
        instrumenter: @instrumenter,
      )

      instrument_payload = { consumer_class: processor.class.to_s }

      # Main loop
      loop do
        break if @stop_requested
        @instrumenter.instrument("main_loop.racecar", instrument_payload) do
          if processor.respond_to?(:process_batch)
            messages = consumer.batch_poll(config.max_wait_time)
            if !messages.empty?
              process_batch(messages)
              consumer.commit # See above. Needed because auto commit is disabled
            end
          elsif processor.respond_to?(:process)
            if message = consumer.poll(config.max_wait_time)
              process(message)
            end
          else
            raise NotImplementedError, "Consumer class must implement process or process_batch method"
          end
        end
      end

      logger.info "Gracefully shutting down"
      processor.deliver!
      processor.teardown
      consumer.commit
      consumer.close
    end

    def stop
      @stop_requested = true
    end

    private

    def producer
      @producer ||= Rdkafka::Config.new(producer_config).producer.tap do |producer|
        producer.delivery_callback = delivery_callback
      end
    end

    def producer_config
      # https://github.com/edenhill/librdkafka/blob/master/CONFIGURATION.md
      producer_config = {
        "bootstrap.servers"      => config.brokers.join(","),
        "client.id"              => config.client_id,
        "statistics.interval.ms" => 1000,
      }
      producer_config["compression.codec"] = config.producer_compression_codec.to_s unless config.producer_compression_codec.nil?
      producer_config.merge(config.rdkafka_producer)
      producer_config
    end

    def delivery_callback
      ->(delivery_report) do
        data = {offset: delivery_report.offset, partition: delivery_report.partition}
        @instrumenter.instrument("acknowledged_message.racecar", data)
      end
    end

    def install_signal_handlers
      # Stop the consumer on SIGINT, SIGQUIT or SIGTERM.
      trap("QUIT") { stop }
      trap("INT")  { stop }
      trap("TERM") { stop }

      # Print the consumer config to STDERR on USR1.
      trap("USR1") { $stderr.puts config.inspect }
    end

    def process(message)
      payload = {
        consumer_class: processor.class.to_s,
        topic: message.topic,
        partition: message.partition,
        offset: message.offset,
      }

      @instrumenter.instrument("process_message.racecar", payload) do
        processor.process(message)
        processor.deliver!
      end
    end

    def process_batch(messages)
      payload = {
        consumer_class: processor.class.to_s,
        topic: messages.first.topic,
        partition: messages.first.partition,
        first_offset: messages.first.offset,
        message_count: messages.size,
      }

      @instrumenter.instrument("process_batch.racecar", payload) do
        processor.process_batch(messages)
        processor.deliver!
      end
    end
  end
end
