const textDecoder = new TextDecoder('utf-8');

/**
  * @param {number[]} array
  * @returns {string}
*/
function arrayToUTF8String(array) {
    return textDecoder.decode(Uint8Array.from(array));
}

export function makeAsyncStream(stream, sep) {
    const SEP_TOKEN = sep.charCodeAt(0);

    const M = {};

    M._callback = null;
    stream.on('readable', () => {
        if (M._callback) {
            if (stream.readableLength === 0)
                M._callback(false);

            const callback = M._callback;
            M._callback = null;
            callback(true);
        }
    });

    M.waitReadable = () => new Promise((resolve) => {
        if (M._callback)
            throw new Error('Another readable is pending');

        if (stream.readableLength > 0) {
            resolve(true);
            return;
        }
        M._callback = resolve;
    });

    M.readByte = async () => {
        if (!await M.waitReadable())
            throw new Error('EOF reached');

        let byte = stream.read(1);
        return byte[0];
    }

    M.readString = async () => {
        const buffer = [];
        while (true) {
            const byte = await M.readByte();
            if (byte === SEP_TOKEN)
                return arrayToUTF8String(buffer);

            buffer.push(byte);
        }
    }

    M.readInt = async () => {
        const str = await M.readString();
        const num = parseInt(str, 10);

        if (isNaN(num) || num < 0)
            throw new Error(`Error: Invalid number: ${str}`);
        return num;
    }

    M.readFloat = async () => {
        const str = await M.readString();
        const num = parseFloat(str);

        if (isNaN(num) || num < 0)
            throw new Error(`Error: Invalid number: ${str}`);
        return num;
    }

    M.readFixedString = async (length) => {
        const buffer = [];
        for (let i = 0; i < length; i++) {
            const byte = await M.readByte();
            buffer.push(byte);
        }
        return arrayToUTF8String(buffer);
    }

    return M;
}
