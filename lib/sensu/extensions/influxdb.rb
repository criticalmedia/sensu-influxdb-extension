require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'em-http-request'
require 'eventmachine'
require 'multi_json'
require 'sensu/extension'
require 'sensu/extensions/influxdb/influx_relay'

module Sensu
  module Extension
    class InfluxDB < Handler
      def name
        definition[:name]
      end

      def definition
        {
          type: 'extension',
          name: 'influxdb'
        }
      end

      def description
        'Outputs metrics to InfluxDB'
      end

      def post_init
        @influx_conf = parse_settings
        logger.info("InfluxDB extension initialiazed using #{@influx_conf['protocol']}://#{@influx_conf['host']}:#{@influx_conf['port']} - Defaults : db=#{@influx_conf['database']} precision=#{@influx_conf['time_precision']}")

        @relay = InfluxRelay.new
        @relay.init(@influx_conf)

        logger.info("InfluxDB write buffer initiliazed : buffer flushed every #{@influx_conf['buffer_max_size']} points OR every #{@influx_conf['buffer_max_age']} seconds) ")
      end

      def run(event_data)
        event = parse_event(event_data)
        if event[:check][:status] != 0
          yield '', 0
          return
        end
        # init event and check data
        client = event[:client][:name]
        event[:check][:influxdb][:database] ||= @influx_conf['database']
        event[:check][:time_precision] ||= @influx_conf['time_precision']
        event[:check][:influxdb][:strip_metric] ||= @influx_conf['strip_metric']
        event[:check][:output].split(/\n/).each do |line|
          key, value, time = line.split(/\s+/)
          values = "value=#{value.to_f}"

          if event[:check][:duration]
            values += ",duration=#{event[:check][:duration].to_f}"
          end

          if event[:check][:influxdb][:strip_metric] == 'host'
            key = slice_host(key, client)
          elsif event[:check][:influxdb][:strip_metric]
            key.gsub!(/^.*#{event[:check][:influxdb][:strip_metric]}\.(.*$)/, '\1')
          end

          # Avoid things break down due to comma in key name
          key.gsub!(',', '\,')
          key.gsub!(/\s/, '\ ')
          key.gsub!('"', '\"')
          key.gsub!('\\') { '\\\\' }

          # This will merge : default conf tags < check embedded tags < sensu client/host tag
          tags = @influx_conf['tags'].merge(event[:check][:influxdb][:tags]).merge('host' => client)
          tags.each do |tag, val|
            key += ",#{tag}=#{val}"
          end
          @relay.push(event[:check][:influxdb][:database], event[:check][:time_precision], [key, values, time.to_i].join(' '))
        end
        yield('', 0)
      end

      def stop
        logger.info('Flushing InfluxDB buffer before exiting')
        @relay.flush_buffer
        true
      end

      private

      def parse_event(event_data)
        event = MultiJson.load(event_data, symbolize_keys: true)

        # default values
        # n, u, ms, s, m, and h (default community plugins use standard epoch date)
        event[:check][:time_precision] ||= nil
        event[:check][:influxdb] ||= {}
        event[:check][:influxdb][:tags] ||= {}
        event[:check][:influxdb][:database] ||= nil
        return event
      rescue => e
        logger.error("Failed to parse event data: #{e}")
      end

      def parse_settings
        settings = @settings['influxdb']

        # default values
        settings['tags'] ||= {}
        settings['use_ssl'] ||= false
        settings['time_precision'] ||= 's'
        settings['protocol'] = settings['use_ssl'] ? 'https' : 'http'
        settings['buffer_max_size'] ||= 500
        settings['buffer_max_age'] ||= 6 # seconds
        settings['port'] ||= 8086
        return settings
      rescue => e
        logger.error("Failed to parse InfluxDB settings #{e}")
      end

      def slice_host(slice, prefix)
        prefix.chars.zip(slice.chars).each do |char1, char2|
          break if char1 != char2
          slice.slice!(char1)
        end
        slice.slice!('.') if slice.chars.first == '.'
        slice
      end

      def logger
        Sensu::Logger.get
      end
    end
  end
end
