require 'spec_helper'

describe CurationConcerns::GenericFileActor do
  include ActionDispatch::TestProcess

  let(:user) { FactoryGirl.create(:user) }
  let(:generic_file) { FactoryGirl.create(:generic_file) }
  let(:actor) { described_class.new(generic_file, user) }
  let(:uploaded_file) { fixture_file_upload('/world.png', 'image/png') }

  describe 'creating metadata and content' do
    let(:upload_set_id) { nil }
    let(:work_id) { nil }
    subject { generic_file.reload }
    let(:date_today) { DateTime.now }

    before do
      allow(DateTime).to receive(:now).and_return(date_today)
    end

    before do
      allow(actor).to receive(:save_characterize_and_record_committer).and_return('true')
      allow(actor).to receive(:acquire_lock_for).and_yield
      actor.create_metadata(upload_set_id, work_id)
      actor.create_content(uploaded_file)
    end

    context 'when an upload_set_id and work_id are not provided' do
      let(:upload_set_id) { nil }
      it "leaves the associations blank" do
        expect(subject.upload_set).to be_nil
        expect(subject.generic_works).to be_empty
      end
    end

    context 'when a upload_set_id is provided' do
      let(:upload_set_id) { ActiveFedora::Noid::Service.new.mint }
      it "leaves the association blank" do
        expect(subject.upload_set).to be_instance_of UploadSet
      end
    end

    context 'when a work_id is provided' do
      let(:work) { FactoryGirl.create(:generic_work) }
      let(:work_id) { work.id }

      it 'adds the generic file to the parent work' do
        expect(subject.generic_works).to eq [work]
        expect(work.reload.generic_files).to include(subject)

        # Confirming that date_uploaded and date_modified were set
        expect(subject.date_uploaded).to eq date_today.utc
        expect(subject.date_modified).to eq date_today.utc
        expect(subject.depositor).to eq user.email

        # Confirm that embargo/lease are not set.
        expect(subject).to_not be_under_embargo
        expect(subject).to_not be_active_lease
        expect(subject.visibility).to eq 'restricted'
      end
    end
  end

  describe "#create_metadata" do
    let(:work) { create(:public_generic_work) }
    let(:work_id) { work.id }

    it 'copies visibility from the parent' do
      allow(actor).to receive(:acquire_lock_for).and_yield
      actor.create_metadata(nil, work_id)
      saved_file = generic_file.reload
      expect(saved_file.visibility).to eq Hydra::AccessControls::AccessRight::VISIBILITY_TEXT_VALUE_PUBLIC
    end
  end

  describe '#create_content' do
    it 'uses the provided mime_type' do
      expect(CharacterizeJob).to receive(:perform_later)
      actor.create_content(uploaded_file)
      expect(generic_file.original_file.mime_type).to eq 'image/png'
    end

    context 'when generic_file.title is empty and generic_file.label is not' do
      let(:file)       { 'world.png' }
      let(:long_name)  { 'an absurdly long title that goes on way to long and messes up the display of the page which should not need to be this big in order to show this impossibly long, long, long, oh so long string' }
      let(:short_name) { 'Nice Short Name' }
      let(:actor)      { described_class.new(generic_file, user) }

      before do
        allow(CharacterizeJob).to receive(:perform_later)
        allow(generic_file).to receive(:label).and_return(short_name)
        actor.create_content(fixture_file_upload(file))
      end

      subject { generic_file.title }

      it { is_expected.to eql [short_name] }
    end

    context 'with two existing versions from different users' do
      let(:file1)       { 'world.png' }
      let(:file2)       { 'small_file.txt' }
      let(:actor1)      { described_class.new(generic_file, user) }
      let(:actor2)      { described_class.new(generic_file, second_user) }

      let(:second_user) { create(:user) }
      let(:versions) { generic_file.original_file.versions }

      before do
        allow(CharacterizeJob).to receive(:perform_later)
        actor1.create_content(fixture_file_upload(file1))
        actor2.create_content(fixture_file_upload(file2))
      end

      it 'has two versions' do
        expect(versions.all.count).to eq 2
      end

      it 'has the current version' do
        expect(CurationConcerns::VersioningService.latest_version_of(generic_file.original_file).label).to eq 'version2'
        expect(generic_file.original_file.content).to eq fixture_file_upload(file2).read
        expect(generic_file.original_file.mime_type).to eq 'text/plain'
        expect(generic_file.original_file.original_name).to eq file2
      end

      it "uses the first version for the object's title and label" do
        expect(generic_file.label).to eql(file1)
        expect(generic_file.title.first).to eql(file1)
      end

      it 'notes the user for each version' do
        expect(VersionCommitter.where(version_id: versions.first.uri).pluck(:committer_login)).to eq [user.user_key]
        expect(VersionCommitter.where(version_id: versions.last.uri).pluck(:committer_login)).to eq [second_user.user_key]
      end
    end

    context 'when a label is already specified' do
      let(:label)    { 'test_file.png' }
      let(:new_file) { 'foo.jpg' }
      let(:generic_file_with_label) do
        GenericFile.new.tap do |f|
          f.apply_depositor_metadata(user.user_key)
          f.label = label
        end
      end
      let(:actor) { described_class.new(generic_file_with_label, user) }

      before do
        allow(actor).to receive(:save_characterize_and_record_committer).and_return('true')
        allow(Hydra::Works::UploadFileToGenericFile).to receive(:call)
        actor.create_content(Tempfile.new(new_file))
      end

      it "will retain the object's original label" do
        expect(generic_file_with_label.label).to eql(label)
      end
    end
  end

  describe "#destroy" do
    it "destroys the object" do
      actor.destroy
      expect { generic_file.reload }.to raise_error ActiveFedora::ObjectNotFoundError
    end
    context "representative of a work" do
      let!(:work) do
        work = FactoryGirl.create(:generic_work)
        # this is not part of a block on the create, since the work must be saved be fore the representative can be assigned
        work.generic_files << generic_file
        work.representative = generic_file.id
        work.save
        work
      end

      it "removes representative" do
        expect(work.reload.representative).to eq(generic_file.id)
        actor.destroy
        expect(work.reload.representative).to be_nil
      end
    end
  end
end
