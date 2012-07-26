#!/usr/bin/env ruby

require 'cgi'

module PuppetDBExtensions

  def self.test_mode=(mode)
    @test_mode = mode
  end
  def self.test_mode()
    @test_mode
  end

  def puppetdb_confdir(host)
    if host.is_pe?
      "/etc/puppetlabs/puppetdb"
    else
      "/etc/puppetdb"
    end
  end

  def start_puppetdb(host)
    on host, "service puppetdb start"
    sleep_until_started(host)
  end

  def sleep_until_started(host)
    # Omit 127 because it means "command not found".
    on host, "curl http://localhost:8080", :acceptable_exit_codes => (0...127)
    num_retries = 0
    until exit_code == 0
      sleep 1
      on host, "curl http://localhost:8080", :acceptable_exit_codes => (0...127)
      num_retries += 1
      if (num_retries > 60)
        fail("Unable to start puppetdb")
      end
    end
  end

  def stop_puppetdb(host)
    on host, "service puppetdb stop"
    sleep_until_stopped(host)
  end

  def sleep_until_stopped(host)
    on host, "curl http://localhost:8080", :acceptable_exit_codes => (0...127)
    num_retries = 0
    until exit_code == 7
      sleep 1
      on host, "curl http://localhost:8080", :acceptable_exit_codes => (0...127)
      num_retries += 1
      if (num_retries > 60)
        fail("Unable to stop puppetdb")
      end
    end
  end

  def restart_puppetdb(host)
    stop_puppetdb(host)
    start_puppetdb(host)
  end

  def sleep_until_queue_empty(host, timeout=nil)
    metric = "org.apache.activemq:BrokerName=localhost,Type=Queue,Destination=com.puppetlabs.puppetdb.commands"
    queue_size = nil

    begin
      Timeout.timeout(timeout) do
        until queue_size == 0
          result = on host, %Q(curl -H 'Accept: application/json' http://localhost:8080/metrics/mbean/#{CGI.escape(metric)} 2> /dev/null |awk -F"," '{for (i = 1; i <= NF; i++) { print $i } }' |grep QueueSize |awk -F ":" '{ print $2 }')
          queue_size = Integer(result.stdout.chomp)
        end
      end
    rescue Timeout::Error => e
      raise "Queue took longer than allowed #{timeout} seconds to empty"
    end
  end
end

PuppetAcceptance::TestCase.send(:include, PuppetDBExtensions)
