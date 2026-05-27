# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  resources :projects, only: [] do
    resources :issue_digest_rules,
              controller: 'issue_digest_rules',
              path: 'digest_rules' do
      member do
        post :enable
        post :disable
      end
    end
  end
end
