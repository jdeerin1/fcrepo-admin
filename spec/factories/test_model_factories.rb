class TestModel < DulHydra::Models::Base
end

class TestContent < TestModel
  include DulHydra::Models::HasContent
end

class TestContentThumbnail < TestContent
  include DulHydra::Models::HasThumbnail
end

class TestParent < TestModel
  has_many :children, :property => :is_part_of, :class_name => 'TestChild', :inbound => true 
end

class TestChild < TestModel
  belongs_to :parent, :property => :is_part_of, :class_name => 'TestParent'
end

class TestFileDatastreams < TestContentThumbnail
  include DulHydra::Models::HasContentdm
  include DulHydra::Models::HasDigitizationGuide
  include DulHydra::Models::HasDPCMetadata
  include DulHydra::Models::HasFMPExport
  include DulHydra::Models::HasJhove
  include DulHydra::Models::HasMarcXML
  include DulHydra::Models::HasTripodMets
end

class TestContentMetadata < TestParent
  include DulHydra::Models::HasContentMetadata
end

FactoryGirl.define do
  
  factory :test_model do
    title "DulHydra Test Object"
    sequence(:identifier) { |n| "test%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
  end
  
  factory :test_parent do
    title "DulHydra Test Parent Object"
    sequence(:identifier) { |n| "testparent%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
    
    factory :test_parent_has_children do
      ignore do
        child_count 3
      end
      after(:create) do |parent, evaluator|
        FactoryGirl.create_list(:test_child, evaluator.child_count, :parent => parent)
      end
    end
  end

  factory :test_child do
    title "DulHydra Test Child Object"
    sequence(:identifier) { |n| "testchild%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
    
    factory :test_child_has_parent do
      association :parent, :factory => :test_parent
    end
  end
  
  factory :test_content do
    title "DulHydra Test Content Object"
    sequence(:identifier) { |n| "testcontent%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
    after(:build) { |c| c.content.content_file = File.new(File.join(Rails.root, "spec", "fixtures", "library-devil.tiff"), "rb") }
      
    factory :test_content_with_fixity_check do
      after(:create) do |c| 
        p = c.validate_content_checksum!
        # XXX PreservationEvents do not have default permissions
        p.permissions = [DulHydra::Permissions::PUBLIC_READ_ACCESS]
        p.save!
      end 
    end
  end
  
  factory :test_content_thumbnail do
    title "DulHydra Test Content Thumbnail Object"
    sequence(:identifier) { |n| "testcontentthumbnail%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
    after(:build) do |c|
      c.content.content_file = File.new(File.join(Rails.root, "spec", "fixtures", "batch_ingest", "miscellaneous", "id001.tif"), "rb")
      c.generate_thumbnail!
    end
  end

  factory :test_content_metadata do
    title "DulHydra Test Content Metadata Object"
    sequence(:identifier) { |n| "testcontentmetadata%05d" % n }
    permissions [DulHydra::Permissions::PUBLIC_READ_ACCESS]
    
    factory :test_content_metadata_has_children do
      ignore do
        child_count 3
      end
      after(:create) do |parent, evaluator|
        FactoryGirl.create_list(:test_child, evaluator.child_count, :parent => parent)
        child_pids = []
        parent.children.each do |child|
          child_pids << child.pid
        end
        parent.contentMetadata.content = <<-EOS
          <mets xmlns="http://www.loc.gov/METS/" xmlns:xlink="http://www.w3.org/1999/xlink">
            <fileSec>
              <fileGrp ID="GRP01" USE="Master Image">
                <file ID="FILE001">
                  <FLocat xlink:href="#{child_pids[2]}/content" LOCTYPE="URL"/>
                </file>
                <file ID="FILE002">
                  <FLocat xlink:href="#{child_pids[0]}/content" LOCTYPE="URL"/>
                </file>
              </fileGrp>
              <fileGrp ID="GRP00" USE="Composite PDF">
                <file ID="FILE000">
                  <FLocat xlink:href="#{child_pids[1]}/content" LOCTYPE="URL"/>
                </file>
              </fileGrp>
            </fileSec>
            <structMap>
              <div ID="DIV01" TYPE="image" LABEL="Images">
                <div ORDER="1">
                  <fptr FILEID="FILE001"/>
                </div>
                <div ORDER="2">
                  <fptr FILEID="FILE002"/>
                </div>
              </div>
              <div ID="DIV00" TYPE="pdf" LABEL="PDF">
                <fptr FILEID="FILE000"/>
              </div>
            </structMap>
          </mets>
        EOS
        parent.contentMetadata.mimeType = "application/xml"
        parent.save!
      end
    end
  end

  
end
  