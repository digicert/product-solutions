package com.example.automation.model;

import lombok.AllArgsConstructor;
import lombok.Getter;

@AllArgsConstructor
public class Result<T> {
    private final boolean isSuccess;
    @Getter private final T value;
    @Getter private final String errorMessage;
    @Getter private final String errorCode;

    public static <U> Result<U> success(U value) {
        return new Result<>(true, value, null, null);
    }

    public static <U> Result<U> success() {
        return new Result<>(true, null, null, null);
    }

    public static <U> Result<U> failure(String errorMessage, String errorCode) {
        return new Result<>(false, null, errorMessage, errorCode);
    }

    public boolean isSuccess() {
        return isSuccess;
    }
}
