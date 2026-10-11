pipeline {
  agent { label 'macos' }

  options {
    timestamps()
    timeout(time: 90, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
    disableConcurrentBuilds()
  }

  environment {
    LANG                   = 'en_US.UTF-8'
    LC_ALL                 = 'en_US.UTF-8'
    FASTLANE_SKIP_UPDATE_CHECK  = '1'
    FASTLANE_DISABLE_COLLECTION = '1'
    FASTLANE_HIDE_CHANGELOG     = '1'
    SIMULATOR_DESTINATION  = 'platform=iOS Simulator,name=iPhone 17'
    // Jenkins runs with a bare PATH (system Ruby 2.6). Prepend Homebrew so we
    // use a modern Ruby + xcbeautify + xcresultparser.
    PATH                   = '/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Install dependencies') {
      steps {
        dir('Marauders-ios') {
          sh 'bundle config set --local path vendor/bundle'
          sh 'bundle install'
        }
      }
    }

    stage('Unit tests') {
      options { retry(2) }
      steps {
        dir('Marauders-ios') {
          sh 'bundle exec fastlane test'
        }
      }
      post {
        always {
          junit allowEmptyResults: true, testResults: 'Marauders-ios/build/test/junit.xml'
        }
      }
    }

    stage('Coverage report') {
      steps {
        dir('Marauders-ios') {
          sh 'xcrun xccov view --report build/test/Marauders.xcresult || true'
        }
      }
    }

    stage('Deploy to TestFlight') {
      when { anyOf { branch 'main'; branch 'master' } }
      steps {
        withCredentials([
          file(credentialsId: 'asc-api-key', variable: 'ASC_KEY_PATH'),
          string(credentialsId: 'asc-key-id', variable: 'ASC_KEY_ID'),
          string(credentialsId: 'asc-issuer-id', variable: 'ASC_ISSUER_ID')
        ]) {
          dir('Marauders-ios') {
            sh 'bundle exec fastlane beta'
          }
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'Marauders-ios/build/*.ipa, Marauders-ios/build/test/Marauders.xcresult/**',
                       allowEmptyArchive: true,
                       fingerprint: true
    }
  }
}
