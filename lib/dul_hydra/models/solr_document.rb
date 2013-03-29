require 'json'

module DulHydra::Models
  module SolrDocument

    def object_profile
      @object_profile ||= JSON.parse(self[:object_profile_ssm].first)
    end

    def datastreams
      object_profile["datastreams"]
    end
    
    def has_datastream?(dsID)
      !(datastreams[dsID].nil? || datastreams[dsID].empty?)
    end

    def has_admin_policy?
      !admin_policy_uri.blank?
    end

    def admin_policy_uri
      get(:is_governed_by_s)
    end

    def admin_policy_pid
      uri = admin_policy_uri
      uri &&= ActiveFedora::Base.pids_from_uris(uri)
    end

    def has_parent?
      !parent_uri
    end

    def parent_uri
      get(:is_part_of_ssim) || get(:is_member_of_ssim) || get(:is_member_of_collection_ssim)
    end

    def parent_pid
      uri = parent_uri
      uri &&= ActiveFedora::Base.pids_from_uris(uri)
    end

    def active_fedora_model
      get(:active_fedora_model_ssim)
    end
    
    def has_thumbnail?
      has_datastream?(DulHydra::Datastreams::THUMBNAIL)
    end

    def has_content?
      has_datastream?(DulHydra::Datastreams::CONTENT)
    end
    
    def targets
      object_uri = ActiveFedora::SolrService.escape_uri_for_query("info:fedora/#{id}")
      query = "is_external_target_for_ssim:#{object_uri}"
      @targets ||= ActiveFedora::SolrService.query(query)
    end
    
    def has_target?
      targets.size > 0 ? true : false
    end
    
    def children
      object_uri = ActiveFedora::SolrService.escape_uri_for_query("info:fedora/#{id}")
      query = "is_member_of_ssim:#{object_uri} OR is_member_of_collection_ssim:#{object_uri} OR is_part_of_ssim:#{object_uri}"
      @children ||= ActiveFedora::SolrService.query(query)
    end
    
    def has_children?
      children.size > 0 ? true : false
    end
    
    def parsed_content_metadata
      JSON.parse(self[:content_metadata_parsed_s].try(:first) || "{}")
    end

  end
end
