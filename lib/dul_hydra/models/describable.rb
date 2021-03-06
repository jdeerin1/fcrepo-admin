module DulHydra::Models
  module Describable
    extend ActiveSupport::Concern
   
    included do
      has_metadata :name => DulHydra::Datastreams::DESC_METADATA, :type => ActiveFedora::QualifiedDublinCoreDatastream,
                   :versionable => true, :label => "Descriptive Metadata for this object", :control_group => 'X'
      delegate_to DulHydra::Datastreams::DESC_METADATA, [:title, :identifier, :creator, :source]
    end

    module ClassMethods
      def find_by_identifier(identifier)
        find(:identifier_t => identifier)
      end
    end

  end
end
