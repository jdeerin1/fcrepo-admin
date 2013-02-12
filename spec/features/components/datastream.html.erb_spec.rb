require 'spec_helper'
require 'support/shared_examples_for_dul_hydra_views'

describe "components/datastream.html.erb" do
  it_behaves_like "a DulHydra object datastream view" do
    subject { page }
    let(:dsid) { "DC" }
    let(:obj) { FactoryGirl.create(:component_public_read) }
    let(:content_path) { component_datastream_content_path(obj, dsid) }
    before { visit component_datastream_path(obj, dsid) }
    after { obj.delete }
  end
end
