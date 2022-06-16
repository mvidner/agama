# frozen_string_literal: true

# Copyright (c) [2022] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "eventmachine"
require "dinstaller/manager"

module DInstaller
  module DBus
    # Set up and run a given D-Bus service
    #
    # @example Run the manager service
    #   runner = ServiceRunner.new(:manager)
    #   runner.run
    #
    # @example Run the users service
    #   runner = ServiceRunner.new(:users)
    #   runner.run
    class ServiceRunner
      # @param name [Symbol,String] Service name (:manager, :users, etc.)
      # @param logger [Logger] Service logger
      def initialize(name, logger: Logger.new($stdout))
        @name = name || :manager
        @logger = logger
      end

      # Run the Service
      #
      # This method listens for D-Bus calls.
      def run
        initialize_yast
        service = build_service(name, logger)
        # TODO: implement a #start method in all services,
        # which is equivalent to #export in most cases.
        service.respond_to?(:start) ? service.start : service.export
        EventMachine.run do
          EventMachine::PeriodicTimer.new(0.1) { service.dispatch }
        end
      end

    private

      attr_reader :name, :logger

      # Configuration
      def config
        Config.load(logger) unless Config.current
        Config.current
      end

      # Set up a service
      #
      # @param name [Symbol] Service name (ie, :users)
      # @param logger [Logger] Service logger
      # @return [#export,#dispatch] Class that implements #export and #dispatch methods.
      def build_service(name, logger)
        require "dinstaller/dbus/#{name}_service"
        klass = DInstaller::DBus.const_get("#{name.capitalize}Service")
        klass.new(config, logger)
      rescue LoadError, NameError
        raise "Service '#{name}' not found"
      end

      # Initializes YaST
      def initialize_yast
        Yast::Mode.SetUI("commandline")
        Yast::Mode.SetMode("installation")
        # Set stage to initial, so it will act as installer for some cases like
        # proposing installer instead of reading current one
        Yast::Stage.Set("initial")
      end
    end
  end
end
