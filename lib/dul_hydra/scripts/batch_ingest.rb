module DulHydra::Scripts
  module BatchIngest
    include DulHydra::Scripts::Helpers::BatchIngestHelper
    def self.prep_for_ingest(ingest_manifest)
      log = config_logger("preparation")
      log.info "=================="
      log.info "Ingest Preparation"
      log.info "Manifest: #{ingest_manifest}"
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
      object_count = 0;
      for object in manifest[:objects]
        key_identifier = key_identifier(object)
        log.info "Processing #{key_identifier}"
        qdcsource = object[:qdcsource] || manifest[:qdcsource]
        if master_source == :objects
          master = add_manifest_object_to_master(master, object, manifest[:model])
        end
        qdc = case
        when qdcsource && QDC_GENERATION_SOURCES.include?(qdcsource.to_sym)
          generate_qdc(object, qdcsource, basepath)
        else
          stub_qdc(object, basepath)
        end
        result_xml_path = "#{basepath}qdc/#{key_identifier(object)}.xml"
        File.open(result_xml_path, 'w') { |f| qdc.write_xml_to f }
        object_count += 1
      end
      unless master_source == PROVIDED
        File.open(master_path(manifest), "w") { |f| master.write_xml_to f }
      end
      log.info "Processed #{object_count} objects"
      log.info "=================="
    end
    def self.ingest(ingest_manifest)
      log_header = "Batch ingest\n"
      log_header << "DulHydra version #{DulHydra::VERSION}\n"
      log_header << "Manifest: #{ingest_manifest}\n"
      manifest = load_yaml(ingest_manifest)
      manifest_apo = AdminPolicy.find(manifest[:adminpolicy]) unless manifest[:adminpolicy].blank?
      manifest_metadata = manifest[:metadata] unless manifest[:metadata].blank?
      master = File.open(master_path(manifest)) { |f| Nokogiri::XML(f) }
      for object in manifest[:objects]
        event_details = log_header
        model = object[:model] || manifest[:model]
        if model.blank?
          raise "Missing model"
        end
        ingest_object = case model
        when "Collection" then Collection.new
        when "Item" then Item.new
        when "Component" then Component.new
        else raise "Invalid model"
        end
        event_details << "Model: #{model}\n"
        event_details << "Identifier(s): "
        case
        when object[:identifier].is_a?(String)
          event_details << "#{object[:identifier]}\n"
        when object[:identifier].is_a?(Array)
          event_details << "#{object[:identifier].join(",")}\n"
        end
        ingest_object.label = object[:label] || manifest[:label]
        ingest_object.admin_policy = object_apo(object, manifest_apo) unless object_apo(object, manifest_apo).nil?
        ingest_object.save
        metadata = object_metadata(object, manifest[:metadata])
        event_details << "Metadata: #{metadata.join(",")}\n"
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
          filename = "#{content_spec[:location]}#{key_identifier(object)}#{content_spec[:extension]}"
          ingest_object = add_content_file(ingest_object, filename)
          event_details << "Content file: #{filename}\n"
        end
        parentid = object[:parentid] || manifest[:parentid]
        if parentid.blank?
          if !manifest[:autoparentidlength].blank?
            parentid = key_identifier(object).slice(0, manifest[:autoparentidlength])
          end
        end
        if !parentid.blank?
          ingest_object = set_parent(ingest_object, model, :id, parentid)
          event_details << "Parent id: #{parentid}\n"
        end
        ingest_object.save
        master = add_pid_to_master(master, key_identifier(object), ingest_object.pid)
        write_preservation_event(ingest_object, PreservationEvent::INGESTION, PreservationEvent::SUCCESS, event_details)
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
      log_header = "Validate ingest\n"
      log_header << "DulHydra version #{DulHydra::VERSION}\n"
      log_header << "Manifest: #{ingest_manifest}\n"
      ingest_valid = true
      manifest = load_yaml(ingest_manifest)
      basepath = manifest[:basepath]
      master = File.open(master_path(manifest)) { |f| Nokogiri::XML(f) }
      checksum_spec = manifest[:checksum]
      if !checksum_spec.blank?
        checksum_doc = File.open("#{basepath}checksum/#{checksum_spec[:location]}") { |f| Nokogiri::XML(f) }
      end
      objects = manifest[:objects]
      objects.each do |object|
        repository_object = nil
        pid_in_master = true
        object_exists = true
        datastream_checksums_valid = true
        datastreams_populated = true
        checksum_matches = true
        parent_child_correct = true
        event_details = log_header
        event_details << "Identifier(s): "
        case
        when object[:identifier].is_a?(String)
          event_details << "#{object[:identifier]}"
        when object[:identifier].is_a?(Array)
          event_details << "#{object[:identifier].join(",")}"
        end
        event_details << "\n"
        begin
          event_details << "#{VERIFYING}PID found in master file"
          pid = get_pid_from_master(master, key_identifier(object))
          if pid.blank?
            pid_in_master = false
          end
        rescue
          pid_in_master = false
        end
        event_details << (pid_in_master ? PASS : FAIL) << "\n"
        if !pid.blank?
          model = object[:model] || manifest[:model]
          if model.blank?
            raise "Missing model for #{key_identifier(object)}"
          end
          event_details << "#{VERIFYING}#{model} object found in repository"
          object_exists = validate_object_exists(model, pid)
          event_details << (object_exists ? PASS : FAIL) << "\n"
          if object_exists
            repository_object = ActiveFedora::Base.find(pid, :cast => true)
            metadata = object_metadata(object, manifest[:metadata])
            expected_datastreams = [ "DC", "RELS-EXT" ]
            metadata.each do |m|
              expected_datastreams << datastream_name(m)
            end
            if !object[:content].blank? || !manifest[:content].blank?
              expected_datastreams << datastream_name("content")
            end
            if !object[:contentstructure].blank? || !manifest[:contentstructure].blank?
              expected_datastreams << datastream_name("contentstructure")
            end
            expected_datastreams.flatten.each do |datastream|
              event_details << "#{VERIFYING}#{datastream} datastream present and not empty"
              datastream_populated = validate_datastream_populated(datastream, repository_object)
              event_details << (datastream_populated ? PASS : FAIL) << "\n"
              if !datastream_populated
                datastreams_populated = false
              end
            end
            datastreams = repository_object.datastreams.values
            datastreams.each do |datastream|
              profile = datastream.profile(:validateChecksum => true)
              if !profile.empty?
                event_details << "#{VERIFYING}#{datastream.dsid} datastream internal checksum"
                if datastream.dsid == "content"
                  preservation_event = PreservationEvent.validate_checksum!(repository_object, datastream.dsid)
                  event_details << (preservation_event.event_outcome == PreservationEvent::SUCCESS ? PASS : FAIL)
                else
                  event_details << (profile["dsChecksumValid"] ? PASS : FAIL) << "\n"
                  if  !profile["dsChecksumValid"]
                    datastream_checksums_valid = false
                  end
                end
              end
            end
            if !checksum_doc.nil?
              event_details << "#{VERIFYING}content datastream external checksum"
              checksum_matches = verify_checksum(repository_object, key_identifier(object), checksum_doc)
              event_details << (checksum_matches ? PASS : FAIL) << "\n"
            end
            parentid = object[:parentid] || manifest[:parentid]
            if parentid.blank?
              if !manifest[:autoparentidlength].blank?
                parentid = key_identifier(object).slice(0, manifest[:autoparentidlength])
              end
            end
            if !parentid.blank?
              event_details << "#{VERIFYING}child relationship to identifier #{parentid}"
              parent = get_parent(repository_object)
              if parent.nil? || !parent.identifier.include?(parentid)
                parent_child_correct = false
              end
              if parent_child_correct
                children = get_children(parent)
                if children.blank? || !children.include?(repository_object)
                  parent_child_correct = false
                end
              end
              event_details << (parent_child_correct ? PASS : FAIL) << "\n"
            end
          end
        end
        object_valid = pid_in_master && object_exists && datastream_checksums_valid && datastreams_populated && checksum_matches && parent_child_correct
        event_details << "Object ingest..." << (object_valid ? "VALIDATES" : "DOES NOT VALIDATE")
        if !object_valid
          ingest_valid = false
        end
        if !repository_object.nil?
          outcome = object_valid ? PreservationEvent::SUCCESS : PreservationEvent::FAILURE
          write_preservation_event(repository_object, PreservationEvent::VALIDATION, outcome, event_details)
        end
      end
      return ingest_valid
    end
  end
end