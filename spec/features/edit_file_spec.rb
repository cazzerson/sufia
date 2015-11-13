require 'spec_helper'

describe "Editing a file:", type: :feature do
  let(:user) { FactoryGirl.create(:user) }
  let(:file_title) { 'Some kind of title' }
  let(:file) do
    FileSet.create!(title: [file_title]) do |f|
      f.apply_depositor_metadata(user.user_key)
    end
  end

  before { sign_in user }

  context 'when the user tries to update file content, but forgets to select a file:' do
    it 'displays an error' do
      visit sufia.edit_file_set_path(file)
      click_link 'Versions'
      click_button 'Upload New Version'
      expect(page).to have_content "Edit #{file_title}"
      expect(page).to have_content 'Please select a file'
    end
  end
end
