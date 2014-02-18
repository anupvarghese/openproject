#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2013 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++
require File.expand_path('../../test_helper', __FILE__)
require 'wiki_controller'

# Re-raise errors caught by the controller.
class WikiController; def rescue_action(e) raise e end; end

class WikiControllerTest < ActionController::TestCase
  fixtures :all

  def setup
    super
    @controller = WikiController.new
    @request    = ActionController::TestRequest.new
    @response   = ActionController::TestResponse.new
    self.current_user = nil
  end

  def wiki
    Project.first.wiki
  end

  def redirect_page
    wiki.find_page(wiki.start_page) || wiki.pages.first
  end

  def test_show_start_page
    get :show, :project_id => 'ecookbook'
    assert_response :success
    assert_template 'show'
    assert_tag :tag => 'h1', :content => /CookBook documentation/

    # child_pages macro
    assert_tag :ul, :attributes => { :class => 'pages-hierarchy' },
               :child => { :tag => 'li',
                           :child => { :tag => 'a', :attributes => { :href => '/projects/ecookbook/wiki/Page_with_an_inline_image' },
                                                    :content => 'Page with an inline image' } }
  end

  def test_show_page_with_name
    get :show, :project_id => 1, :id => 'Another_page'
    assert_response :success
    assert_template 'show'
    assert_tag :tag => 'h1', :content => /Another page/
    # Included page with an inline image
    assert_tag :tag => 'p', :content => /This is an inline image/
    assert_tag :tag => 'img', :attributes => { :src => '/attachments/3/download',
                                               :alt => 'This is a logo' }
  end

  def test_show_with_sidebar
    page = Project.find(1).wiki.pages.new(:title => 'Sidebar')
    page.content = WikiContent.new(:text => 'Side bar content for test_show_with_sidebar')
    page.save!

    get :show, :project_id => 1, :id => 'Another_page'
    assert_response :success
    assert_tag :tag => 'div', :attributes => {:id => 'sidebar'},
                              :content => /Side bar content for test_show_with_sidebar/
  end

  def test_show_unexistent_page_without_edit_right
    get :show, :project_id => 1, :id => 'Unexistent page'
    assert_response 404
  end

  def test_show_unexistent_page_with_edit_right
    @request.session[:user_id] = 2
    get :show, :project_id => 1, :id => 'Unexistent page'
    assert_response :success
    assert_template 'edit'
  end

  def test_create_page
    @request.session[:user_id] = 2
    put :update, :project_id => 1,
                :id => 'New page',
                :content => {:comments => 'Created the page',
                             :text => "h1. New page\n\nThis is a new page" }
    assert_redirected_to :action => 'show', :project_id => 'ecookbook', :id => 'New_page'
    page = wiki.find_page('New page')
    assert !page.new_record?
    assert_not_nil page.content
    assert_equal 'Created the page', page.content.last_journal.notes
  end

  def test_create_page_with_attachments
    @request.session[:user_id] = 2
    assert_difference 'WikiPage.count' do
      assert_difference 'Attachment.count' do
        put :update, :project_id => 1,
                    :id => 'New page',
                    :content => {:comments => 'Created the page',
                                 :text => "h1. New page\n\nThis is a new page",
                                 :lock_version => 0},
                    :attachments => {'1' => {'file' => uploaded_test_file('testfile.txt', 'text/plain')}}
      end
    end
    page = wiki.find_page('New page')
    assert_equal 1, page.attachments.count
    assert_equal 'testfile.txt', page.attachments.first.filename
  end

  def test_update_page
    page = Wiki.find(1).pages.find_by_title('Another_page')
    page.content.recreate_initial_journal!

    @request.session[:user_id] = 2
    assert_no_difference 'WikiPage.count' do
      assert_no_difference 'WikiContent.count' do
        assert_difference 'Journal.count' do
          put :update, :project_id => 1,
            :id => 'Another_page',
            :content => {
              :comments => "my comments",
              :text => "edited",
              :lock_version => 2
            }
        end
      end
    end
    assert_redirected_to '/projects/ecookbook/wiki/Another_page'

    page.reload
    assert_equal "edited", page.content.text
    assert_equal page.content.journals.map(&:version).max, page.content.version
    assert_equal "my comments", page.content.last_journal.notes
  end

  def test_update_page_with_failure
    @request.session[:user_id] = 2
    assert_no_difference 'WikiPage.count' do
      assert_no_difference 'WikiContent.count' do
        assert_no_difference 'Journal.count' do
          put :update, :project_id => 1,
            :id => 'Another_page',
            :content => {
              :comments => 'a' * 300,  # failure here, comment is too long
              :text => 'edited',
              :lock_version => 1
            }
          end
        end
      end
    assert_response :success
    assert_template 'edit'

    assert_error_tag :descendant => {:content => /Comment is too long/}
    assert_tag :tag => 'textarea', :attributes => {:id => 'content_text'}, :content => /edited/
    assert_tag :tag => 'input', :attributes => {:id => 'content_lock_version', :value => '1'}
  end

  def test_update_stale_page_should_not_raise_an_error
    journal = FactoryGirl.create :wiki_content_journal,
                                 journable_id: 2,
                                 data: FactoryGirl.build(:journal_wiki_content_journal,
                                                         text: "h1. Another page\n\n\nthis is a link to ticket: #2")
    @request.session[:user_id] = 2
    c = Wiki.find(1).find_page('Another_page').content
    c.text = 'Previous text'
    c.save!
    assert_equal 2, c.version

    assert_no_difference 'WikiPage.count' do
      assert_no_difference 'WikiContent.count' do
        assert_no_difference 'Journal.count' do
          put :update, :project_id => 1,
            :id => 'Another_page',
            :content => {
              :comments => 'My comments',
              :text => 'Text should not be lost',
              :lock_version => 1
            }
        end
      end
    end
    assert_response :success
    assert_template 'edit'
    assert_tag :div,
      :attributes => { :class => /error/ },
      :content => /Information has been updated by at least one other user in the meantime/
    assert_tag 'textarea',
      :attributes => { :name => 'content[text]' },
      :content => /Text should not be lost/
    assert_tag 'input',
      :attributes => { :name => 'content[comments]', :value => 'My comments' }

    c.reload
    assert_equal 'Previous text', c.text
    assert_equal journal.version, c.version
  end

  def test_preview
    @request.session[:user_id] = 2
    xhr :post, :preview, :project_id => 1, :id => 'CookBook_documentation',
                                   :content => { :comments => '',
                                                 :text => 'this is a *previewed text*',
                                                 :lock_version => 3 }
    assert_response :success
    assert_template 'common/_preview'
    assert_tag :tag => 'strong', :content => /previewed text/
  end

  def test_preview_new_page
    @request.session[:user_id] = 2
    xhr :post, :preview, :project_id => 1, :id => 'New page',
                                   :content => { :text => 'h1. New page',
                                                 :comments => '',
                                                 :lock_version => 0 }
    assert_response :success
    assert_template 'common/_preview'
    assert_tag :tag => 'h1', :content => /New page/
  end

  def test_history
    FactoryGirl.create :wiki_content_journal,
                       journable_id: 1,
                       data: FactoryGirl.build(:journal_wiki_content_journal,
                                               text: "h1. CookBook documentation")
    FactoryGirl.create :wiki_content_journal,
                       journable_id: 1,
                       data: FactoryGirl.build(:journal_wiki_content_journal,
                                               text: "h1. CookBook documentation\n\n\nSome updated [[documentation]] here...")
    FactoryGirl.create :wiki_content_journal,
                       journable_id: 1,
                       data: FactoryGirl.build(:journal_wiki_content_journal,
                                               text: "h1. CookBook documentation\nSome updated [[documentation]] here...")

    get :history, :project_id => 1, :id => 'CookBook_documentation'
    assert_response :success
    assert_template 'history'
    assert_not_nil assigns(:versions)
    assert_equal 3, assigns(:versions).size
    assert_select "input[type=submit][name=commit]"
  end

  def test_history_with_one_version
    FactoryGirl.create :wiki_content_journal,
                       journable_id: 2,
                       data: FactoryGirl.build(:journal_wiki_content_journal,
                                               text: "h1. Another page\n\n\nthis is a link to ticket: #2")
    get :history, :project_id => 1, :id => 'Another_page'
    assert_response :success
    assert_template 'history'
    assert_not_nil assigns(:versions)
    assert_equal 1, assigns(:versions).size
    assert_select "input[type=submit][name=commit]", false
  end

  def test_diff
    journal_from = FactoryGirl.create :wiki_content_journal,
                                      journable_id: 1,
                                      data: FactoryGirl.build(:journal_wiki_content_journal,
                                                              text: "h1. CookBook documentation")
    journal_to = FactoryGirl.create :wiki_content_journal,
                                    journable_id: 1,
                                    data: FactoryGirl.build(:journal_wiki_content_journal,
                                                            text: "h1. CookBook documentation\n\n\nSome updated [[documentation]] here...")

    get :diff, :project_id => 1, :id => 'CookBook_documentation', :version => journal_to.version, :version_from => journal_from.version
    assert_response :success
    assert_template 'diff'
    assert_tag :tag => 'ins', :attributes => { :class => 'diffins'},
                              :content => /updated/
  end

  def test_annotate
    FactoryGirl.create :wiki_content_journal,
                       journable_id: 1,
                       data: FactoryGirl.build(:journal_wiki_content_journal,
                                               text: "h1. CookBook documentation")
    journal_to = FactoryGirl.create :wiki_content_journal,
                                    journable_id: 1,
                                    data: FactoryGirl.build(:journal_wiki_content_journal,
                                                            text: "h1. CookBook documentation\n\n\nSome [[documentation]] here...")

    get :annotate, :project_id => 1, :id =>  'CookBook_documentation', :version => journal_to.version
    assert_response :success
    assert_template 'annotate'
    # Line 1
    assert_tag :tag => 'tr', :child => { :tag => 'th', :attributes => {:class => 'line-num'}, :content => '1' },
                             :child => { :tag => 'td', :attributes => {:class => 'author'}, :content => /John Smith/ },
                             :child => { :tag => 'td', :content => /h1\. CookBook documentation/ }
    # Line 2
    assert_tag :tag => 'tr', :child => { :tag => 'th', :attributes => {:class => 'line-num'}, :content => '2' },
                             :child => { :tag => 'td', :attributes => {:class => 'author'}, :content => /redMine Admin/ },
                             :child => { :tag => 'td', :content => /Some updated \[\[documentation\]\] here/ }
  end

  def test_get_rename
    @request.session[:user_id] = 2
    get :rename, :project_id => 1, :id => 'Another_page'
    assert_response :success
    assert_template 'rename'
  end

  def test_get_rename_child_page
    @request.session[:user_id] = 2
    get :rename, :project_id => 1, :id => 'Child_1'
    assert_response :success
    assert_template 'rename'
  end

  def test_rename_with_redirect
    @request.session[:user_id] = 2
    put :rename, :project_id => 1, :id => 'Another_page',
                 :page => { :title => 'Another renamed page',
                            :redirect_existing_links => 1 }
    assert_redirected_to :action => 'show', :project_id => 'ecookbook', :id => 'Another_renamed_page'
    # Check redirects
    assert_not_nil wiki.find_page('Another page')
    assert_nil wiki.find_page('Another page', :with_redirect => false)
  end

  def test_rename_without_redirect
    @request.session[:user_id] = 2
    put :rename, :project_id => 1, :id => 'Another_page',
                 :page => { :title => 'Another renamed page',
                            :redirect_existing_links => "0" }
    assert_redirected_to :action => 'show', :project_id => 'ecookbook', :id => 'Another_renamed_page'
    # Check that there's no redirects
    assert_nil wiki.find_page('Another page')
  end

  def test_destroy_child
    @request.session[:user_id] = 2
    delete :destroy, :project_id => 1, :id => 'Child_1'
    assert_redirected_to action: 'index', project_id: 'ecookbook', id: redirect_page
  end

  def test_destroy_parent
    @request.session[:user_id] = 2
    assert_no_difference('WikiPage.count') do
      delete :destroy, :project_id => 1, :id => 'Another_page'
    end
    assert_response :success
    assert_template 'destroy'
  end

  def test_destroy_parent_with_nullify
    @request.session[:user_id] = 2
    assert_difference('WikiPage.count', -1) do
      delete :destroy, :project_id => 1, :id => 'Another_page', :todo => 'nullify'
    end
    assert_redirected_to action: 'index', project_id: 'ecookbook', id: redirect_page
    assert_nil WikiPage.find_by_id(2)
  end

  def test_destroy_parent_with_cascade
    @request.session[:user_id] = 2
    assert_difference('WikiPage.count', -3) do
      delete :destroy, :project_id => 1, :id => 'Another_page', :todo => 'destroy'
    end
    assert_redirected_to action: 'index', project_id: 'ecookbook', id: redirect_page
    assert_nil WikiPage.find_by_id(2)
    assert_nil WikiPage.find_by_id(5)
  end

  def test_destroy_parent_with_reassign
    @request.session[:user_id] = 2
    assert_difference('WikiPage.count', -1) do
      delete :destroy, :project_id => 1, :id => 'Another_page', :todo => 'reassign', :reassign_to_id => 1
    end
    assert_redirected_to action: 'index', project_id: 'ecookbook', id: redirect_page
    assert_nil WikiPage.find_by_id(2)
    assert_equal WikiPage.find(1), WikiPage.find_by_id(5).parent
  end

  def test_index
    get :index, :project_id => 'ecookbook'
    assert_response :success
    assert_template 'index'
    pages = assigns(:pages)
    assert_not_nil pages
    assert_equal wiki.pages.size, pages.size
    assert_equal pages.first.content.updated_on, pages.first.updated_on

    assert_tag :ul, :attributes => { :class => 'pages-hierarchy' },
                    :child => { :tag => 'li', :child => { :tag => 'a', :attributes => { :href => '/projects/ecookbook/wiki/CookBook_documentation' },
                                              :content => 'CookBook documentation' },
                                :child => { :tag => 'ul',
                                            :child => { :tag => 'li',
                                                        :child => { :tag => 'a', :attributes => { :href => '/projects/ecookbook/wiki/Page_with_an_inline_image' },
                                                                                 :content => 'Page with an inline image' } } } },
                    :child => { :tag => 'li', :child => { :tag => 'a', :attributes => { :href => '/projects/ecookbook/wiki/Another_page' },
                                                                       :content => 'Another page' } }
  end

  def test_index_should_include_atom_link
    get :index, :project_id => 'ecookbook'
    assert_tag 'a', :attributes => { :href => '/projects/ecookbook/activity.atom?show_wiki_edits=1'}
  end

  context "GET :export" do
    context "with an authorized user to export the wiki" do
      setup do
        @request.session[:user_id] = 2
        get :export, :project_id => 'ecookbook'
      end

      should respond_with :success
      should_assign_to :pages
      should_respond_with_content_type "text/html"
      should "export all of the wiki pages to a single html file" do
        assert_select "a[name=?]", "CookBook_documentation"
        assert_select "a[name=?]", "Another_page"
        assert_select "a[name=?]", "Page_with_an_inline_image"
      end

    end

    context "with an unauthorized user" do
      setup do
        get :export, :project_id => 'ecookbook'

        should respond_with :redirect
        should redirect_to('wiki index') { {:action => 'show', :project_id => @project, :id => nil} }
      end
    end
  end

  context "GET :date_index" do
    setup do
      get :date_index, :project_id => 'ecookbook'
    end

    should respond_with :success
    should_assign_to :pages
    should_assign_to :pages_by_date
    should render_template 'wiki/date_index'

    should "include atom link" do
      assert_tag 'a', :attributes => { :href => '/projects/ecookbook/activity.atom?show_wiki_edits=1'}
    end
  end

  def test_not_found
    get :show, :project_id => 999
    assert_response 404
  end

  def test_protect_page
    page = WikiPage.find_by_wiki_id_and_title(1, 'Another_page')
    assert !page.protected?
    @request.session[:user_id] = 2
    post :protect, :project_id => 1, :id => page.title, :protected => '1'
    assert_redirected_to :action => 'show', :project_id => 'ecookbook', :id => 'Another_page'
    assert page.reload.protected?
  end

  def test_unprotect_page
    page = WikiPage.find_by_wiki_id_and_title(1, 'CookBook_documentation')
    assert page.protected?
    @request.session[:user_id] = 2
    post :protect, :project_id => 1, :id => page.title, :protected => '0'
    assert_redirected_to :action => 'show', :project_id => 'ecookbook', :id => 'CookBook_documentation'
    assert !page.reload.protected?
  end

  def test_show_page_with_edit_link
    @request.session[:user_id] = 2
    get :show, :project_id => 1
    assert_response :success
    assert_template 'show'
    assert_tag :tag => 'a', :attributes => { :href => '/projects/1/wiki/CookBook_documentation/edit' }
  end

  def test_show_page_without_edit_link
    @request.session[:user_id] = 4
    get :show, :project_id => 1
    assert_response :success
    assert_template 'show'
    assert_no_tag :tag => 'a', :attributes => { :href => '/projects/1/wiki/CookBook_documentation/edit' }
  end

  def test_edit_unprotected_page
    # Non members can edit unprotected wiki pages
    @request.session[:user_id] = 4
    get :edit, :project_id => 1, :id => 'Another_page'
    assert_response :success
    assert_template 'edit'
  end

  def test_edit_protected_page_by_nonmember
    # Non members can't edit protected wiki pages
    @request.session[:user_id] = 4
    get :edit, :project_id => 1, :id => 'CookBook_documentation'
    assert_response 403
  end

  def test_edit_protected_page_by_member
    @request.session[:user_id] = 2
    get :edit, :project_id => 1, :id => 'CookBook_documentation'
    assert_response :success
    assert_template 'edit'
  end

  def test_history_of_non_existing_page_should_return_404
    get :history, :project_id => 1, :id => 'Unknown_page'
    assert_response 404
  end
end
