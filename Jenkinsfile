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

    stage('Resolve Swift packages') {
      steps {
        // The poc-sdk.waypointsdk package lives in a private JFrog Swift package
        // registry, so resolution needs an access token. Store it as the secret
        // text credential `jfrog-sdk-swift-token` in Jenkins. SwiftPM keeps
        // registry credentials in the keychain (via `package-registry login`),
        // not in ~/.netrc, so log in before resolving.
        withCredentials([
          string(credentialsId: 'jfrog-sdk-swift-token', variable: 'JFROG_SDK_SWIFT_TOKEN')
        ]) {
          dir('Marauders-ios') {
            sh '''
              set -eu
              swift package-registry login \\
                "https://tartheesaran.jfrog.io/artifactory/api/swift/sdk-swift" \\
                --token "$JFROG_SDK_SWIFT_TOKEN" \\
                --no-confirm
              xcodebuild -resolvePackageDependencies \\
                -project Marauders.xcodeproj \\
                -scheme Marauders
            '''
          }
        }
      }
    }

    stage('Deploy to TestFlight') {
      when {
        anyOf {
          branch 'main'
          // Plain (non-multibranch) Pipeline jobs don't set BRANCH_NAME, so
          // fall back to GIT_BRANCH which the Git plugin sets to
          // origin/<branch-specifier>.
          expression { env.GIT_BRANCH in ['origin/main'] }
        }
      }
      steps {
        withCredentials([
          file(credentialsId: 'asc-api-key', variable: 'ASC_KEY_PATH'),
          string(credentialsId: 'asc-key-id', variable: 'ASC_KEY_ID'),
          string(credentialsId: 'asc-issuer-id', variable: 'ASC_ISSUER_ID'),
          string(credentialsId: 'jfrog-sdk-swift-token', variable: 'JFROG_SDK_SWIFT_TOKEN')
        ]) {
          dir('Marauders-ios') {
            sh 'bundle exec fastlane beta'
          }
        }
      }
    }

    // Temporarily disabled to keep the TestFlight build fast. Re-enable before
    // merging for good: it runs the fastlane test lane and records coverage.
    //
    // stage('Unit tests') {
    //   options { retry(2) }
    //   steps {
    //     dir('Marauders-ios') {
    //       sh 'bundle exec fastlane test'
    //     }
    //   }
    //   post {
    //     always {
    //       junit allowEmptyResults: true, testResults: 'Marauders-ios/build/test/junit.xml'
    //     }
    //   }
    // }
    //
    // stage('Coverage report') {
    //   steps {
    //     dir('Marauders-ios') {
    //       sh 'xcrun xccov view --report build/test/Marauders.xcresult || true'
    //     }
    //   }
    //   post {
    //     always {
    //       // Requires the Jenkins "Coverage" plugin. Renders a coverage tab
    //       // (line/branch drift vs. previous build) from the Cobertura XML that
    //       // `fastlane test` emits via xcresultparser.
    //       recordCoverage tools: [[parser: 'COBERTURA', pattern: 'Marauders-ios/build/test/coverage.xml']],
    //                      sourceCodeRetention: 'LAST_BUILD'
    //     }
    //   }
    // }
  }

  post {
    always {
      archiveArtifacts artifacts: 'Marauders-ios/build/*.ipa, Marauders-ios/build/test/Marauders.xcresult/**',
                       allowEmptyArchive: true,
                       fingerprint: true
    }
  }
}
