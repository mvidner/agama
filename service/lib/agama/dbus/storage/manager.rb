# frozen_string_literal: true

# Copyright (c) [2022-2023] SUSE LLC
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

require "dbus"
require "yast"
require "agama/dbus/base_object"
require "agama/dbus/with_service_status"
require "agama/dbus/interfaces/progress"
require "agama/dbus/interfaces/service_status"
require "agama/dbus/interfaces/validation"
require "agama/dbus/interfaces/dasd"
require "agama/dbus/storage/proposal"
require "agama/dbus/storage/proposal_settings_converter"
require "agama/dbus/storage/volume_converter"
require "agama/dbus/storage/with_iscsi_auth"
require "agama/dbus/storage/iscsi_nodes_tree"

Yast.import "Arch"

module Agama
  module DBus
    module Storage
      # D-Bus object to manage storage installation
      class Manager < BaseObject
        include WithISCSIAuth
        include WithServiceStatus
        include ::DBus::ObjectManager
        include DBus::Interfaces::Progress
        include DBus::Interfaces::ServiceStatus
        include DBus::Interfaces::Validation

        PATH = "/org/opensuse/Agama/Storage1"
        private_constant :PATH

        # Constructor
        #
        # @param backend [Agama::Storage::Manager]
        # @param logger [Logger]
        def initialize(backend, logger)
          super(PATH, logger: logger)
          @backend = backend
          register_proposal_callbacks
          register_progress_callbacks
          register_service_status_callbacks
          register_iscsi_callbacks
          register_software_callbacks
          return unless Yast::Arch.s390

          singleton_class.include DBus::Interfaces::Dasd
          register_and_extend_dasd_callbacks
        end

        STORAGE_INTERFACE = "org.opensuse.Agama.Storage1"
        private_constant :STORAGE_INTERFACE

        def probe
          busy_while do
            backend.probe
            storage_properties_changed
          end
        end

        def install
          busy_while { backend.install }
        end

        def finish
          busy_while { backend.finish }
        end

        # Whether the system is in a deprecated status
        #
        # @return [Boolean]
        def deprecated_system
          backend.deprecated_system
        end

        dbus_interface STORAGE_INTERFACE do
          dbus_method(:Probe) { probe }
          dbus_method(:Install) { install }
          dbus_method(:Finish) { finish }
          dbus_reader(:deprecated_system, "b")
        end

        PROPOSAL_CALCULATOR_INTERFACE = "org.opensuse.Agama.Storage1.Proposal.Calculator"
        private_constant :PROPOSAL_CALCULATOR_INTERFACE

        # List of disks available for installation
        #
        # Each device is represented by an array containing the name of the device and the label to
        # represent that device in the UI when further information is needed.
        #
        # @return [Array<String, String, Hash>]
        def available_devices
          proposal.available_devices.map do |dev|
            [dev.name, proposal.device_label(dev), {}]
          end
        end

        # Volumes used as template for creating a new proposal
        #
        # @return [Hash]
        def volume_templates
          converter = VolumeConverter.new
          proposal.volume_templates.map { |v| converter.to_dbus(v) }
        end

        # Path of the D-Bus object containing the calculated proposal
        #
        # @return [::DBus::ObjectPath] Proposal object path or root path if no exported proposal yet
        def result
          dbus_proposal&.path || ::DBus::ObjectPath.new("/")
        end

        # Calculates a new proposal
        #
        # @param dbus_settings [Hash]
        # @return [Integer] 0 success; 1 error
        def calculate_proposal(dbus_settings)
          logger.info("Calculating storage proposal from D-Bus settings: #{dbus_settings}")

          converter = ProposalSettingsConverter.new
          success = proposal.calculate(converter.to_agama(dbus_settings))

          success ? 0 : 1
        end

        dbus_interface PROPOSAL_CALCULATOR_INTERFACE do
          dbus_reader :available_devices, "a(ssa{sv})"

          dbus_reader :volume_templates, "aa{sv}"

          dbus_reader :result, "o"

          # result: 0 success; 1 error
          dbus_method :Calculate, "in settings:a{sv}, out result:u" do |settings|
            busy_while { calculate_proposal(settings) }
          end
        end

        ISCSI_INITIATOR_INTERFACE = "org.opensuse.Agama.Storage1.ISCSI.Initiator"
        private_constant :ISCSI_INITIATOR_INTERFACE

        # Gets the iSCSI initiator name
        #
        # @return [String]
        def initiator_name
          backend.iscsi.initiator.name || ""
        end

        # Sets the iSCSI initiator name
        #
        # @param value [String]
        def initiator_name=(value)
          backend.iscsi.initiator.name = value
        end

        # Whether the initiator name was set via iBFT
        #
        # @return [Boolean]
        def ibft
          backend.iscsi.initiator.ibft_name?
        end

        # Performs an iSCSI discovery
        #
        # @param address [String] IP address of the iSCSI server
        # @param port [Integer] Port of the iSCSI server
        # @param options [Hash<String, String>] Options from a D-Bus call:
        #   @option Username [String] Username for authentication by target
        #   @option Password [String] Password for authentication by target
        #   @option ReverseUsername [String] Username for authentication by initiator
        #   @option ReversePassword [String] Username for authentication by inititator
        #
        # @return [Integer] 0 on success, 1 on failure
        def iscsi_discover(address, port, options = {})
          success = backend.iscsi.discover_send_targets(address, port, iscsi_auth(options))
          success ? 0 : 1
        end

        # Deletes an iSCSI node from the database
        #
        # @param path [::DBus::ObjectPath]
        # @return [Integer] 0 on success, 1 on failure if the given node is not exported, 2 on
        #   failure because any other reason.
        def iscsi_delete(path)
          dbus_node = iscsi_nodes_tree.find(path)
          if !dbus_node
            logger.info("iSCSI delete error: iSCSI node #{path} is not exported")
            return 1
          end

          success = backend.iscsi.delete(dbus_node.iscsi_node)
          return 0 if success

          logger.info("iSCSI delete error: fail to delete iSCSI node #{path}")
          2 # Error code
        end

        dbus_interface ISCSI_INITIATOR_INTERFACE do
          dbus_accessor :initiator_name, "s"

          dbus_reader :ibft, "b", dbus_name: "IBFT"

          dbus_method :Discover,
            "in address:s, in port:u, in options:a{sv}, out result:u" do |address, port, options|
            busy_while { iscsi_discover(address, port, options) }
          end

          dbus_method(:Delete, "in node:o, out result:u") { |n| iscsi_delete(n) }
        end

      private

        # @return [Agama::Storage::Manager]
        attr_reader :backend

        # @return [DBus::Storage::Proposal, nil]
        attr_reader :dbus_proposal

        # @return [Agama::Storage::Proposal]
        def proposal
          backend.proposal
        end

        def register_proposal_callbacks
          proposal.on_calculate do
            export_proposal
            proposal_properties_changed
            update_validation
          end
        end

        def register_iscsi_callbacks
          backend.iscsi.on_activate do
            properties = interfaces_and_properties[ISCSI_INITIATOR_INTERFACE]
            dbus_properties_changed(ISCSI_INITIATOR_INTERFACE, properties, [])
          end

          backend.iscsi.on_probe do
            refresh_iscsi_nodes
          end

          backend.iscsi.on_sessions_change do
            deprecate_system
          end
        end

        def register_software_callbacks
          backend.software.on_product_selected do |_product|
            backend.proposal.reset
          end
        end

        def register_and_extend_dasd_callbacks
          register_dasd_callbacks

          dasd_backend.on_refresh do |_|
            deprecate_system
          end
        end

        def deprecate_system
          backend.deprecated_system = true
          storage_properties_changed
          update_validation
        end

        def storage_properties_changed
          properties = interfaces_and_properties[STORAGE_INTERFACE]
          dbus_properties_changed(STORAGE_INTERFACE, properties, [])
        end

        def proposal_properties_changed
          properties = interfaces_and_properties[PROPOSAL_CALCULATOR_INTERFACE]
          dbus_properties_changed(PROPOSAL_CALCULATOR_INTERFACE, properties, [])
        end

        def export_proposal
          @service.unexport(dbus_proposal) if dbus_proposal
          @dbus_proposal = DBus::Storage::Proposal.new(proposal, logger)
          @service.export(@dbus_proposal)
        end

        def refresh_iscsi_nodes
          nodes = backend.iscsi.nodes
          iscsi_nodes_tree.update(nodes)
        end

        def iscsi_nodes_tree
          @iscsi_nodes_tree ||= ISCSINodesTree.new(@service, backend.iscsi, logger: logger)
        end
      end
    end
  end
end
