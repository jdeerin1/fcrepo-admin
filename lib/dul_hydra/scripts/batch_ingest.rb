module DulHydra::Scripts
  module BatchIngest
    include DulHydra::Scripts::Helpers::BatchIngestHelper
    def self.prep_for_ingest(ingest_manifest)
      manifest = load_yaml(ingest_manifest)
      basepath = manifest[:basepath]
      master_source = manifest[:mastersource] || :objects
      unless master_source == PROVIDED
        master = create_master_document()
      end
      for object in manifest[:objects]
        key_identifier = key_identifier(object)
        if master_source == :objects
          master = add_manifest_object_to_master(master, object, manifest[:model])
        end
        case object[:qdcsource]
        when "contentdm"
          xml = File.open(metadata_filepath("contentdm", object, basepath)) { |f| Nokogiri::XML(f) }
          xslt = File.open(CONTENTDM_TO_QDC_XSLT_FILEPATH) { |f| Nokogiri::XSLT(f) }
          qdc = xslt.transform(xml)
          result_xml_path = "#{basepath}qdc/#{key_identifier(object)}.xml"
          File.open(result_xml_path, 'w') { |f| qdc.write_xml_to f }          
        when "marcxml"
          xml = File.open(metadata_filepath("marcxml", object, basepath)) { |f| Nokogiri::XML(f) }
          xslt = File.open(MARCXML_TO_QDC_XSLT_FILEPATH) { |f| Nokogiri::XSLT(f) }
          qdc = xslt.transform(xml)
          result_xml_path = "#{basepath}qdc/#{key_identifier(object)}.xml"
          File.open(result_xml_path, 'w') { |f| qdc.write_xml_to f }
        end
      end
      unless master_source == PROVIDED
        File.open(master_path(manifest), "w") { |f| master.write_xml_to f }
      end
    end
    def self.ingest(ingest_manifest)
      File.open(ingest_manifest) { |f| manifest = YAML::load(f) }
      logger.debug(ingest_manifest)
      manifest_apo = AdminPolicy.find(manifest[:adminpolicy]) unless manifest[:adminpolicy].blank?
      for object in manifest[:objects]
        apo = case
        when object[:adminpolicy] then AdminPolicy.find(object[:adminpolicy])
        when manifest_apo then manifest_apo
        end
        model = object[:model] || manifest[:model]
        if model.blank?
          raise "Missing model"
        end
        ingest_object = case model
        when "afmodel:Collection" then Collection.new
        when "afmodel:Item" then Item.new
        when "afmodel:Component" then Component.new
        else raise "Invalid model"
        end
        ingest_object.label = object[:label] || manifest[:label]
        ingest_object.identifier = object[:identifier]
        ingest_object.title = object[:title] || manifest[:title]
        ingest_object.admin_policy = apo unless apo.nil?
        ingest_object.save
      end
    end
  end
end