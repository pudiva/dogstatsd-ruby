require 'spec_helper'

describe Datadog::Statsd::UDPConnection do
  subject do
    described_class.new(host, port, logger: logger, telemetry: telemetry)
  end

  let(:host) do
    '192.168.1.1'
  end

  let(:port) do
    4567
  end

  let(:logger) do
    Logger.new(log).tap do |logger|
      logger.level = Logger::DEBUG
    end
  end
  let(:log) { StringIO.new }

  let(:telemetry) do
    instance_double(Datadog::Statsd::Telemetry)
  end

  before do
    allow(UDPSocket)
      .to receive(:new)
      .and_return(udp_socket)
  end

  let(:udp_socket) do
    instance_double(UDPSocket, connect: true, send: true)
  end

  describe '#initialize' do
    it 'uses the provided host' do
      expect(subject.host).to eq '192.168.1.1'
    end

    it 'uses the provided port' do
      expect(subject.port).to eq 4567
    end

    context 'when no host is provided' do
      let(:host) do
        nil
      end

      it 'uses the default host' do
        expect(subject.host).to eq Datadog::Statsd::UDPConnection::DEFAULT_HOST
      end

      context 'when DD_AGENT_HOST env var is provided' do
        around do |example|
          ClimateControl.modify('DD_AGENT_HOST' => 'myhost') do
            example.run
          end
        end

        it 'uses the environment variable DD_AGENT_HOST to set the host' do
          expect(subject.host).to eq 'myhost'
        end
      end
    end

    context 'when no port is provided' do
      let(:port) do
        nil
      end

      it 'uses the default port' do
        expect(subject.port).to eq Datadog::Statsd::UDPConnection::DEFAULT_PORT
      end

      context 'when DD_DOGSTATSD_PORT env var is provided' do
        around do |example|
          ClimateControl.modify('DD_DOGSTATSD_PORT' => '1337') do
            example.run
          end
        end

        it 'uses the environment variable DD_DOGSTATSD_PORT to set the port' do
          expect(subject.port).to eq 1337
        end
      end
    end
  end

  describe '#write' do
    let(:telemetry) do
      instance_double(Datadog::Statsd::Telemetry, sent: true, dropped: true)
    end

    it 'connects to the right host and port' do
      expect(udp_socket)
        .to receive(:connect)
        .with('192.168.1.1', 4567)

      subject.write('test')
    end

    it 'updates the "sent" telemetry counts' do
      expect(telemetry)
        .to receive(:sent)
        .with(bytes: 4, packets: 1)

      subject.write('test')
    end

    it 'logs the sent message in debug mode' do
      subject.write('test')

      expect(log.string).to match %r{DEBUG -- : Statsd: test}
    end

    context 'when writing fails' do
      before do
        allow(UDPSocket).to receive(:new).and_return(fake_socket, fake_socket_retry)
      end

      let(:fake_socket) do
        instance_double(UDPSocket,
          connect: true,
          send: true)
      end

      let(:fake_socket_retry) do
        instance_double(UDPSocket,
          connect: true,
          send: true)
      end

      context 'when having unknown SocketError (drop strategy)'do
        before do
          allow(fake_socket)
            .to receive(:send)
            .and_raise(SocketError, 'unknown error')
        end

        it 'connects to the right host and port' do
          expect(fake_socket)
            .to receive(:connect)
            .with('192.168.1.1', 4567)

          subject.write('test')
        end

        it 'updates the "dropped" telemetry counts' do
          expect(telemetry)
            .to receive(:dropped)
            .with(bytes: 4, packets: 1)

          subject.write('test')
        end

        it 'tries to send through socket' do
          expect(fake_socket)
            .to receive(:send)
            .with('foobar', anything)

          subject.write('foobar')
        end

        it 'ignores the writing failure (message dropped)' do
          expect do
            subject.write('foobar')
          end.not_to raise_error
        end

        it 'does not retry to reopen the socket' do
          expect(UDPSocket)
            .to receive(:new)
            .once

          subject.write('foobar')
        end

        it 'logs the error message' do
          subject.write('foobar')

          expect(log.string).to match 'Statsd: SocketError unknown error'
        end
      end

      context 'when having closed sockets (retry strategy)'do
        before do
          allow(fake_socket)
            .to receive(:send)
            .and_raise(IOError.new('closed stream'))

          allow(fake_socket)
            .to receive(:close)
        end

        context 'when retrying is working' do
          it 'connects the first socket to the right host and port' do
            expect(fake_socket)
              .to receive(:connect)
              .with('192.168.1.1', 4567)

            subject.write('test')
          end

          it 'tries to send through the initial socket' do
            expect(fake_socket)
              .to receive(:send)
              .with('foobar', anything)

            subject.write('foobar')
          end

          it 'close the initial socket' do
            expect(fake_socket)
              .to receive(:close)

            subject.write('foobar')
          end

          it 'retries on the second opened socket' do
            expect(fake_socket_retry)
              .to receive(:send)
              .with('foobar', anything)

            subject.write('foobar')
          end

          it 'connects the second socket to the right host and port' do
            expect(fake_socket_retry)
              .to receive(:connect)
              .with('192.168.1.1', 4567)

            subject.write('test')
          end

          it 'updates the "sent" telemetry counts' do
            expect(telemetry)
              .to receive(:sent)
              .with(bytes: 4, packets: 1)

            subject.write('test')
          end
        end

        context 'when retrying fails' do
          context 'because of an unknown error' do
            before do
              allow(fake_socket_retry)
                .to receive(:send)
                .and_raise(RuntimeError, 'yolo')
            end

            it 'tries to send through the initial socket' do
              expect(fake_socket)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'retries on the second opened socket' do
              expect(fake_socket_retry)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'ignores the connection failure' do
              expect do
                subject.write('foobar')
              end.not_to raise_error
            end

            it 'logs the error message' do
              subject.write('foobar')
              expect(log.string).to match 'Statsd: RuntimeError yolo'
            end

            it 'connects the first socket to the right host and port' do
              expect(fake_socket)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'close the initial socket' do
              expect(fake_socket)
                .to receive(:close)

              subject.write('foobar')
            end

            it 'connects the second socket to the right host and port' do
              expect(fake_socket_retry)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'updates the "dropped" telemetry counts' do
              expect(telemetry)
                .to receive(:dropped)
                .with(bytes: 4, packets: 1)

              subject.write('test')
            end
          end

          context 'because of a SocketError' do
            before do
              allow(fake_socket_retry)
                .to receive(:send)
                .and_raise(SocketError, 'yolo')
            end

            it 'ignores the connection failure' do
              expect do
                subject.write('foobar')
              end.not_to raise_error
            end

            it 'logs the error message' do
              subject.write('foobar')
              expect(log.string).to match 'Statsd: SocketError yolo'
            end

            it 'updates the "dropped" telemetry counts' do
              expect(telemetry)
                .to receive(:dropped)
                .with(bytes: 4, packets: 1)

              subject.write('test')
            end

            it 'tries to send through the initial socket' do
              expect(fake_socket)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'close the initial socket' do
              expect(fake_socket)
                .to receive(:close)

              subject.write('foobar')
            end

            it 'retries on the second opened socket' do
              expect(fake_socket_retry)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'connects the first socket to the right host and port' do
              expect(fake_socket)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'connects the second socket to the right host and port' do
              expect(fake_socket_retry)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'updates the "dropped" telemetry counts' do
              expect(telemetry)
                .to receive(:dropped)
                .with(bytes: 4, packets: 1)

              subject.write('test')
            end
          end
        end
      end

      context 'when having connection refused (retry strategy)' do
        before do
          allow(fake_socket)
            .to receive(:send)
            .and_raise(Errno::ECONNREFUSED.new('closed stream'))

          allow(fake_socket)
            .to receive(:close)
        end

        context 'when retrying is working' do
          it 'tries with the initial socket' do
            expect(fake_socket)
              .to receive(:send)
              .with('foobar', anything)

            subject.write('foobar')
          end

          it 'close the initial socket' do
            expect(fake_socket)
              .to receive(:close)

            subject.write('foobar')
          end

          it 'retries on the second opened socket' do
            expect(fake_socket_retry)
              .to receive(:send)
              .with('foobar', anything)

            subject.write('foobar')
          end

          it 'connects the first socket to the right host and port' do
            expect(fake_socket)
              .to receive(:connect)
              .with('192.168.1.1', 4567)

            subject.write('test')
          end

          it 'connects the second socket to the right host and port' do
            expect(fake_socket_retry)
              .to receive(:connect)
              .with('192.168.1.1', 4567)

            subject.write('test')
          end

          it 'updates the "sent" telemetry counts' do
            expect(telemetry)
              .to receive(:sent)
              .with(bytes: 4, packets: 1)

            subject.write('test')
          end
        end

        context 'when retrying fails' do
          context 'because of an unknown error' do
            before do
              allow(fake_socket_retry)
                .to receive(:send)
                .and_raise(RuntimeError, 'yolo')
            end

            it 'ignores the connection failure' do
              expect do
                subject.write('foobar')
              end.not_to raise_error
            end

            it 'logs the error message' do
              subject.write('foobar')
              expect(log.string).to match 'Statsd: RuntimeError yolo'
            end

            it 'tries to send through the initial socket' do
              expect(fake_socket)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'close the initial socket' do
              expect(fake_socket)
                .to receive(:close)

              subject.write('foobar')
            end

            it 'retries on the second opened socket' do
              expect(fake_socket_retry)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'connects the first socket to the right host and port' do
              expect(fake_socket)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end
            it 'connects the second socket to the right host and port' do
              expect(fake_socket_retry)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'updates the "dropped" telemetry counts' do
              expect(telemetry)
                .to receive(:dropped)
                .with(bytes: 4, packets: 1)

              subject.write('test')
            end
          end

          context 'because of connection still refused' do
            before do
              allow(fake_socket_retry)
                .to receive(:send)
                .and_raise(Errno::ECONNREFUSED, 'yolo')
            end

            it 'ignores the connection failure' do
              expect do
                subject.write('foobar')
              end.not_to raise_error
            end

            it 'logs the error message' do
              subject.write('foobar')
              expect(log.string).to match 'Errno::ECONNREFUSED Connection refused - yolo'
            end

            it 'tries to send through the initial socket' do
              expect(fake_socket)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'close the initial socket' do
              expect(fake_socket)
                .to receive(:close)

              subject.write('foobar')
            end

            it 'retries on the second opened socket' do
              expect(fake_socket_retry)
                .to receive(:send)
                .with('foobar', anything)

              subject.write('foobar')
            end

            it 'connects the first socket to the right host and port' do
              expect(fake_socket)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end
            it 'connects the second socket to the right host and port' do
              expect(fake_socket_retry)
                .to receive(:connect)
                .with('192.168.1.1', 4567)

              subject.write('test')
            end

            it 'updates the "dropped" telemetry counts' do
              expect(telemetry)
                .to receive(:dropped)
                .with(bytes: 4, packets: 1)

              subject.write('test')
            end
          end
        end
      end
    end
  end
end


# This instance is only about testing when the connection is opened

describe Datadog::Statsd::UDPConnection do
  subject do
    described_class.new(host, port, logger: logger, telemetry: telemetry)
  end
  let(:host) do
    'fakedomain'
  end
  let(:port) do
    4567
  end
  let(:logger) do
    Logger.new(STDOUT)
  end
  let(:telemetry) do
    instance_double(Datadog::Statsd::Telemetry, sent: true, dropped: true)
  end
  describe '#initialize' do
    it 'is not immediately opening the connection' do
      expect(subject).not_to receive(:connect)
    end
  end
  describe '#write' do
    it 'is opening the connection' do
      expect(subject).to receive(:connect)
      subject.write("hello")
    end
  end
end
