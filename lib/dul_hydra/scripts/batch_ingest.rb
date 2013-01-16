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
      if manifest[:split]
        for entry in manifest[:split]
          source_doc_path = case
          when entry[:source].start_with?("/")
            entry[:source]
          else
            "#{basepath}#{entry[:type]}/#{entry[:source]}"
          end
          source_doc = File.open(source_doc_path) { |f| Nokogiri::XML(f) }
          parts = split(source_doc, entry[:xpath], entry[:idelement])
          parts.each { | key, value |
            target_path = entry[:targetpath] || "#{basepath}#{entry[:type]}/"
            File.open("#{target_path}#{key}.xml", 'w') { |f| value.write_xml_to f }
          }
        end
      end
      checksum_spec = manifest[:checksum]
      if !checksum_spec.blank?
        if checksum_spec.size == 1
          checksum_doc = File.open("#{basepath}checksum/#{checksum_spec.first[:location]}") { |f| Nokogiri::XML(f) }
          checksum_source =  "#{checksum_spec.first[:source]}"
        else
          raise "Multiple checksum specifications in manifest"
        end
      end
      for object in manifest[:objects]
        key_identifier = key_identifier(object)
        qdcsource = object[:qdcsource] || manifest[:qdcsource]
        if master_source == :objects
          master = add_manifest_object_to_master(master, object, manifest[:model])
        end
        if !checksum_doc.nil?
          master = add_checksum_to_master(master, key_identifier, checksum_doc, checksum_source)
        end
        qdc = case
        when qdcsource && QDC_GENERATION_SOURCES.include?(qdcsource.to_sym)
          generate_qdc(object, qdcsource, basepath)
        else
          stub_qdc(object, basepath)
        end
        result_xml_path = "#{basepath}qdc/#{key_identifier(object)}.xml"
        File.open(result_xml_path, 'w') { |f| qdc.write_xml_to f }        
      end
      unless master_source == PROVIDED
        File.open(master_path(manifest), "w") { |f| master.write_xml_to f }
      end
    end
    def self.ingest(ingest_manifest)
      manifest = load_yaml(ingest_manifest)
      manifest_apo = AdminPolicy.find(manifest[:adminpolicy]) unless manifest[:adminpolicy].blank?
      manifest_metadata = manifest[:metadata] unless manifest[:metadata].blank?
      master = File.open(master_path(manifest)) { |f| Nokogiri::XML(f) }
      for object in manifest[:objects]
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
        ingest_object.admin_policy = object_apo(object, manifest_apo) unless object_apo(object, manifest_apo).nil?
        ingest_object.save
        metadata = object_metadata(object, manifest[:metadata])
        if object_metadata(object, manifest_metadata).include?("qdc")
          qdc = File.open("#{manifest[:basepath]}qdc/#{key_identifier(object)}.xml") { |f| f.read }
          ingest_object.descMetadata.content = qdc
          ingest_object.descMetadata.dsLabel = "Descriptive Metadata for this object"
          ingest_object.identifier = merge_identifiers(object[:identifier], ingest_object.identifier)
        end
        ["contentdm", "digitizationguide", "dpcmetadata", "fmpexport", "jhove", "marcxml", "tripodmets"].each do |metadata_type|
          if object_metadata(object, manifest_metadata).include?(metadata_type)
            ingest_object = add_metadata_content_file(ingest_object, object, metadata_type, manifest[:basepath])
          end
        end
        content_spec = object[:content] || manifest[:content]
        if !content_spec.blank?
          if content_spec.size == 1
            ingest_object = add_content_file(ingest_object, content_spec.first, key_identifier(object));
          else
            raise "Multiple content specifications in manifest"
          end
        end
        parentid = object[:parentid] || manifest[:parentid]
        if parentid.blank?
          if !manifest[:autoparentidlength].blank?
            parentid = key_identifier(object).slice(0, manifest[:autoparentidlength])
          end
        end
        if !parentid.blank?
          ingest_object = set_parent(ingest_object, model, :id, parentid)
        end
        ingest_object.save
        master = add_pid_to_master(master, key_identifier(object), ingest_object.pid)
      end
      File.open(master_path(manifest), "w") { |f| master.write_xml_to f }
    end
    def self.post_process_ingest(ingest_manifest)
      manifest = load_yaml(ingest_manifest)
      if !manifest[:contentstructure].blank?
        case manifest[:contentstructure][:type]
        when "generate"
          sequence_start = manifest[:contentstructure][:sequencestart]
          sequence_length = manifest[:contentstructure][:sequencelength]
          manifest_items = manifest[:objects]
          manifest_items.each do |manifest_item|
            identifier = key_identifier(manifest_item)
            items = Item.find_by_identifier(identifier)
            case items.size
            when 1
              item = items.first
              content_metadata = create_content_metadata_document(item, sequence_start, sequence_length)
              filename = "#{manifest[:basepath]}contentmetadata/#{identifier}.xml"
              File.open(filename, 'w') { |f| content_metadata.write_xml_to f }
              item = add_metadata_content_file(item, manifest_item, "contentmetadata", manifest[:basepath])
              item.save
            when 0
              raise "Item #{identifier} not found"
            else
              raise "Multiple items #{identifier} found"
            end
          end
        end
      end
    end
    def self.validate_ingest(ingest_manifest)
      valid = true
      manifest = load_yaml(ingest_manifest)
      master = File.open(master_path(manifest)) { |f| Nokogiri::XML(f) }
      objects = manifest[:objects]
      objects.each do |object|
        pid = get_pid_from_master(master, key_identifier(object))
        model = object[:model] || manifest[:model]
        if model.blank?
          raise "Missing model for #{key_identifier(object)}"
        end
        begin
          repository_object = case model
          when "afmodel:Collection" then Collection.find(pid)
          when "afmodel:Item" then Item.find(pid)
          when "afmodel:Component" then Component.find(pid)
          else raise "Invalid model for #{key_identifier(object)}"
          end
        rescue ActiveFedora::ObjectNotFoundError
          valid = false
          puts "Object not found in repository"
          puts "---Model: #{model}"
          puts "---Identifier: #{key_identifier(object)}"
          puts "---Pid: #{pid}"          
        end
      end
      return valid
    end
  end
end